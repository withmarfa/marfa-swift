import CryptoKit
import Foundation

/// What the HTTP calls of a sign-in and a renewal run on.
///
/// Tests swap in a scripted session, a short time limit and a clock that does not wait.
struct SignInTransport: Sendable {
    var session: URLSession
    /// The longest a token request may take before a renewal gives up and reports the server unavailable.
    var timeLimit: Duration = .seconds(30)
    /// The longest a renewal may hold the lease in all, its token request, metadata read and retry together.
    ///
    /// A renewal that gives up at `timeLimit` leaves its requests running, still holding the lease, until they
    /// answer or this passes. It must stay well within two `leaseLifetime`s, the time a caller waiting for the
    /// lease gives up after, so that a sign-out or a sign-in in this process waits for a renewal to finish, and
    /// it must be at least `timeLimit`, since a retry is sent only when `timeLimit` of it is left.
    var requestLimit: Duration = .seconds(60)
    /// How long a ``RenewalLease`` lasts unless its holder moves it on, after which another holder may take it.
    var leaseLifetime: Duration = .seconds(60)
    var leasePoll: Duration = .milliseconds(100)
    /// The clock a ``RenewalLease`` lapses on, in nanoseconds, which every process sharing the keychain must
    /// read alike.
    var leaseClock: @Sendable () -> UInt64 = RenewalLease.uptime
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @Sendable () -> Date = { Date() }

    static let standard: SignInTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return SignInTransport(session: URLSession(configuration: configuration))
    }()

    /// The request as it is sent: with the contract this build was made for.
    func prepared(_ request: URLRequest) -> URLRequest {
        var request = request
        ContractHeader.apply(to: &request, path: request.url?.path ?? "")
        return request
    }

    /// Sends `request` and answers whatever the server answers first, a redirect included, never following it.
    ///
    /// Every request a sign-in or a renewal sends goes through this or ``dataTask(for:completion:)``, so no
    /// session the transport holds can send one on to another address.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: prepared(request), delegate: RefusedRedirects.shared)
    }

    /// A task for `request` that answers a redirect as it is, never following it.
    ///
    /// The caller resumes it.
    func dataTask(
        for request: URLRequest, completion: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDataTask {
        let task = session.dataTask(with: prepared(request), completionHandler: completion)
        task.delegate = RefusedRedirects.shared
        return task
    }
}

private final class RefusedRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RefusedRedirects()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The device code grant's type, as RFC 8628 names it.
let deviceCodeGrant = "urn:ietf:params:oauth:grant-type:device_code"

/// `scheme://host[:port]`, lowercased, with the scheme's default port left out.
package func origin(of url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
        let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
    else { return nil }
    let shown = host.contains(":") ? "[\(host)]" : host
    switch (scheme, url.port) {
    case (_, nil), ("http", 80), ("https", 443): return "\(scheme)://\(shown)"
    case (_, let port?): return "\(scheme)://\(shown):\(port)"
    }
}

/// The sign-in kept for one server: the client the app registered there and the tokens it holds.
///
/// One keychain item holds all of it, so a reader never sees a token beside another sign-in's client.
struct KeptSignIn: Codable, Sendable, Equatable {
    var clientId: String
    /// The grants the client was registered for.
    var grantTypes: [String]
    var redirect: String?
    var accessToken: String
    var refreshToken: String?
    var scope: String?
    var tokenEndpoint: String
    var revocationEndpoint: String?
    /// Whether a renewal's request was cut off with no answer.
    ///
    /// The server may then have rotated the grant to a refresh token this sign-in does not hold. A renewal that
    /// is answered clears it.
    var uncertain = false

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case grantTypes = "grant_types"
        case redirect
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case scope
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case uncertain
    }
}

extension KeptSignIn {
    /// A sign-in kept before `uncertain` existed reads as certain.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try values.decode(String.self, forKey: .clientId)
        grantTypes = try values.decode([String].self, forKey: .grantTypes)
        redirect = try values.decodeIfPresent(String.self, forKey: .redirect)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
        scope = try values.decodeIfPresent(String.self, forKey: .scope)
        tokenEndpoint = try values.decode(String.self, forKey: .tokenEndpoint)
        revocationEndpoint = try values.decodeIfPresent(String.self, forKey: .revocationEndpoint)
        uncertain = try values.decodeIfPresent(Bool.self, forKey: .uncertain) ?? false
    }
}

/// Where one server's sign-in lives in the keychain.
struct SignInPlace: Sendable, Hashable {
    let keychain: Keychain
    let service: String
    /// The server's origin.
    let account: String

    /// Another process renewing the same sign-in holds this item while it does.
    var leaseAccount: String { "\(account) renewing" }

    func read() throws -> KeptSignIn? {
        guard let data = try keychain.data(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(KeptSignIn.self, from: data)
    }

    func keep(_ kept: KeptSignIn) throws {
        try keychain.put(try JSONEncoder().encode(kept), service: service, account: account)
    }

    func drop() throws {
        try keychain.delete(service: service, account: account)
    }

    /// Runs `work` while holding the place's ``RenewalLease``, so no renewal or other sign-in write of this
    /// process or another runs at the same time.
    ///
    /// Blocks the calling thread while another holder has the lease; never call it on the main thread. Throws
    /// ``SignInError/heldElsewhere`` when the lease stays held past the wait.
    func exclusively<T>(_ transport: SignInTransport, _ work: () throws -> T) throws -> T {
        let lease: RenewalLease
        do {
            lease = try RenewalLease.take(self, transport)
        } catch is RenewalLease.Held {
            throw SignInError.heldElsewhere
        }
        defer { lease.release() }
        return try work()
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// The authorization server metadata a sign-in reads, held to the server it was read from.
struct Discovery: Sendable, Decodable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let deviceAuthorizationEndpoint: String
    let registrationEndpoint: String
    let revocationEndpoint: String?
    let authorizationResponseIssParameterSupported: Bool?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case deviceAuthorizationEndpoint = "device_authorization_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
    }

    /// RFC 9207 section 2.4: an authorization response names the issuer it came from, and the app refuses one
    /// that names another, or none when the metadata says the server sends it.
    ///
    /// The comparison is a plain string comparison against `issuer`, as the RFC says, so the same issuer
    /// written another way is another issuer.
    func accepts(issuer returned: String?) -> Bool {
        guard let returned else { return authorizationResponseIssParameterSupported != true }
        return returned == issuer
    }

    static func read(_ server: String, _ transport: SignInTransport) async throws(SignInError) -> Discovery {
        guard let at = URL(string: "\(server)/.well-known/oauth-authorization-server") else {
            throw .unreadable(message: "\(server) is not an address a sign-in can use")
        }
        return try parse(try await send(URLRequest(url: at), transport), from: server)
    }

    /// The metadata `answer` holds, read from `server` and held to it.
    ///
    /// RFC 8414 section 3.3: the document must name the server it was read from as its issuer, because the
    /// app is about to send a person's approval to the addresses it names.
    static func parse(_ answer: Answer, from server: String) throws(SignInError) -> Discovery {
        guard answer.status == 200 else { throw answer.refusal() }
        let discovery: Discovery
        do {
            discovery = try JSONDecoder().decode(Discovery.self, from: answer.body)
        } catch {
            throw .unreadable(message: "the sign-in metadata at \(server) is not one this package reads")
        }
        guard let issuer = URL(string: discovery.issuer).flatMap(origin(of:)), issuer == server else {
            throw .unreadable(message: "\(server) names \(discovery.issuer) as its issuer, so it is not signed in to")
        }
        let doors = [
            discovery.authorizationEndpoint, discovery.tokenEndpoint, discovery.deviceAuthorizationEndpoint,
            discovery.registrationEndpoint,
        ]
        for door in doors + [discovery.revocationEndpoint].compactMap(\.self)
        where URL(string: door).flatMap(origin(of:)) != server {
            throw .unreadable(message: "\(server) sends a sign-in to \(door), off its own address")
        }
        return discovery
    }
}

/// An answer from the server: its status, body and `Retry-After`.
struct Answer: Sendable {
    let status: Int
    let body: Data
    let retryAfter: Duration?

    var object: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }

    /// The body of an error answer, 4xx or 5xx.
    ///
    /// A redirect's body is never read for a code, so whatever it holds,
    /// a redirect is refused as `http_<status>` and never taken for a pending, slowed or ended grant.
    private var refusalObject: [String: Any]? { status >= 400 ? object : nil }

    /// RFC 6749's `error` string, which only an OAuth endpoint's own refusal carries.
    var oauthError: String? { refusalObject?["error"] as? String }

    /// The OAuth error code, or the code of Marfa's error envelope.
    var code: String? {
        if let oauthError { return oauthError }
        return (refusalObject?["error"] as? [String: Any])?["code"] as? String
    }

    var message: String {
        guard let object = refusalObject else { return "the server answered \(status)" }
        if let text = object["error_description"] as? String { return text }
        if let text = (object["error"] as? [String: Any])?["message"] as? String { return text }
        return "the server answered \(status)"
    }

    func refusal() -> SignInError {
        .refused(code: code ?? "http_\(status)", message: message)
    }

    init(status: Int, body: Data, headers: [AnyHashable: Any]) {
        self.status = status
        self.body = body
        let header = headers.first { ($0.key as? String)?.lowercased() == "retry-after" }?.value as? String
        retryAfter = header.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { .seconds($0) }
    }
}

func formRequest(_ url: String, _ fields: [(String, String)]) throws(SignInError) -> URLRequest {
    guard let at = URL(string: url) else { throw .unreadable(message: "\(url) is not an address") }
    var request = URLRequest(url: at)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    var form = URLComponents()
    form.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
    // `URLComponents` leaves `+` alone in a query, which a form body reads as a space.
    let encoded = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
    request.httpBody = Data(encoded.utf8)
    return request
}

func send(_ request: URLRequest, _ transport: SignInTransport) async throws(SignInError) -> Answer {
    do {
        let (body, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SignInError.unreadable(message: "the server's answer is not HTTP")
        }
        return Answer(status: http.statusCode, body: body, headers: http.allHeaderFields)
    } catch let error as SignInError {
        throw error
    } catch is CancellationError {
        throw .canceled
    } catch let error as URLError where error.code == .cancelled {
        throw .canceled
    } catch {
        throw .unavailable(message: "the server could not be reached: \(error.localizedDescription)")
    }
}

/// A token endpoint's answer.
struct TokenAnswer: Decodable {
    let accessToken: String
    let refreshToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case scope
    }

    static func read(_ answer: Answer) throws(SignInError) -> TokenAnswer {
        guard let token = try? JSONDecoder().decode(TokenAnswer.self, from: answer.body), !token.accessToken.isEmpty
        else { throw .unreadable(message: "the token answer is not one this package reads") }
        return token
    }
}

/// RFC 7636: a verifier of 32 random bytes and its S256 challenge.
struct ProofKey: Sendable {
    let verifier: String
    let challenge: String

    init() {
        verifier = randomText()
        challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

func randomText() -> String {
    var generator = SystemRandomNumberGenerator()
    return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
