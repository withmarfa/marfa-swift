import Foundation
import Synchronization

@testable import Marfa

/// A Marfa authorization server played from a script.
///
/// It is reached through a `URLSession` whose requests never leave the process. Each server has a host of its
/// own, so tests that run at once never share one.
final class ScriptedAuthServer: Sendable {
    indirect enum Reply: Sendable {
        case json(Int, [String: any Sendable], headers: [String: String] = [:])
        /// Answers `body` as it is, with only the headers named.
        case raw(Int, Data, headers: [String: String] = [:])
        /// Never answers, as a server that has gone quiet.
        case silence
        case failure(URLError.Code)
        /// Answers `reply` once `delay` has passed, unless the request was canceled first.
        case delayed(Duration, Reply)
        /// Answers `reply` once the test lets `hold` go, unless the request was canceled first.
        case held(Hold, Reply)
    }

    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        var form: [String: String] {
            var form = URLComponents()
            form.percentEncodedQuery = String(decoding: body, as: UTF8.self)
            var fields: [String: String] = [:]
            for item in form.queryItems ?? [] { fields[item.name] = item.value ?? "" }
            return fields
        }

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    let origin: String
    let url: URL
    private let handler: Mutex<@Sendable (Request) -> Reply>
    private let seen = Mutex<[Request]>([])

    init(_ handler: @escaping @Sendable (Request) -> Reply = { _ in .json(404, [:]) }) {
        let host = "\(UUID().uuidString.lowercased()).example"
        origin = "https://\(host)"
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        url = components.url ?? URL(filePath: "/")
        self.handler = Mutex(handler)
        Self.servers.withLock { $0[host] = self }
    }

    func answer(_ handler: @escaping @Sendable (Request) -> Reply) {
        self.handler.withLock { $0 = handler }
    }

    var requests: [Request] { seen.withLock { $0 } }
    func requests(to path: String) -> [Request] { requests.filter { $0.path == path } }

    /// The transport a sign-in under test uses: requests reach this process's scripted servers, a pause moves
    /// `clock` on instead of waiting, and leases lapse only when the test moves `leases` on.
    ///
    /// Its limits are far beyond what a test takes on a loaded machine. A test of a limit sets it, and holds
    /// back what must come after it rather than racing it.
    func transport(clock: TestClock = TestClock(), leases: LeaseClock = LeaseClock()) -> SignInTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        var transport = SignInTransport(session: URLSession(configuration: configuration))
        transport.timeLimit = .seconds(40)
        transport.requestLimit = .seconds(50)
        transport.leaseLifetime = .seconds(30)
        transport.leasePoll = .milliseconds(20)
        transport.leaseClock = { leases.now }
        transport.sleep = { duration in
            try Task.checkCancellation()
            clock.advance(duration)
        }
        transport.now = { clock.now }
        return transport
    }

    /// What `/.well-known/oauth-authorization-server/auth` answers, naming this server.
    func discovery(issuer: String? = nil) -> Reply {
        .json(
            200,
            [
                "issuer": issuer ?? "\(origin)/auth",
                "authorization_endpoint": "\(origin)/auth/oauth2/authorize",
                "token_endpoint": "\(origin)/auth/oauth2/token",
                "device_authorization_endpoint": "\(origin)/auth/device/code",
                "registration_endpoint": "\(origin)/auth/oauth2/register",
                "revocation_endpoint": "\(origin)/auth/oauth2/revoke",
            ])
    }

    fileprivate static let servers = Mutex<[String: ScriptedAuthServer]>([:])

    fileprivate func handle(_ request: Request) -> Reply {
        seen.withLock { $0.append(request) }
        let handler = self.handler.withLock { $0 }
        return handler(request)
    }
}

/// A clock a test moves by hand.
final class TestClock: Sendable {
    private let moment = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    private let slept = Mutex<[Duration]>([])

    var now: Date { moment.withLock { $0 } }
    var pauses: [Duration] { slept.withLock { $0 } }

    func advance(_ duration: Duration) {
        slept.withLock { $0.append(duration) }
        moment.withLock { $0 = $0.addingTimeInterval(duration.seconds) }
    }
}

/// The clock a test's leases lapse on, which stands still until the test moves it.
///
/// Whether a lease has lapsed then never depends on how quickly a loaded machine runs the heartbeat.
final class LeaseClock: Sendable {
    private let moment = Mutex(RenewalLease.uptime())

    var now: UInt64 { moment.withLock { $0 } }

    func advance(_ duration: Duration) {
        moment.withLock { $0 += RenewalLease.nanoseconds(duration) }
    }
}

/// A reply held back until the test lets it go.
final class Hold: Sendable {
    private let waiting = Mutex<(released: Bool, deliveries: [@Sendable () -> Void])>((false, []))

    func release() {
        let deliveries = waiting.withLock { waiting in
            waiting.released = true
            defer { waiting.deliveries = [] }
            return waiting.deliveries
        }
        for deliver in deliveries { deliver() }
    }

    fileprivate func then(_ deliver: @escaping @Sendable () -> Void) {
        let now = waiting.withLock { waiting in
            if waiting.released { return true }
            waiting.deliveries.append(deliver)
            return false
        }
        if now { deliver() }
    }
}

final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let server = ScriptedAuthServer.servers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let headers = (request.allHTTPHeaderFields ?? [:])
        let reply = server.handle(
            .init(method: request.httpMethod ?? "GET", path: url.path(), headers: headers, body: body))
        deliver(reply, for: url)
    }

    private func deliver(_ reply: ScriptedAuthServer.Reply, for url: URL) {
        if stopped.withLock({ $0 }) { return }
        switch reply {
        case .silence:
            return
        case .delayed(let delay, let later):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay.seconds) { self.deliver(later, for: url) }
        case .held(let hold, let later):
            hold.then { self.deliver(later, for: url) }
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let status, let object, let extra):
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            deliver(.raw(status, data, headers: ["Content-Type": "application/json"].merging(extra) { $1 }), for: url)
        case .raw(let status, let data, let headers):
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            if (300..<400).contains(status), let location = headers["Location"], let target = URL(string: location) {
                // A real server's redirect is offered to the session, which follows it unless its delegate refuses.
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}
