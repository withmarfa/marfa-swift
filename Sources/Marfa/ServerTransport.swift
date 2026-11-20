import Foundation
internal import MarfaTypes
import Synchronization

/// The session a client's requests go through, closed when the last client using it is released.
package final class Connection: Sendable {
    package let session: URLSession

    package init(base: URLSession?, timeout: Duration) {
        let configuration = base?.configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest =
            Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        session = URLSession(configuration: configuration, delegate: RefusesRedirects(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }
}

/// A followed redirect could carry the credential to another host, so the redirect itself is the answer.
private final class RefusesRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// The error an answer stands for, or `nil` for a success from a server speaking this build's contract.
///
/// `body` is read only for an answer that is not a success. `declaredCode` is the `X-Error-Code` header, which names
/// a server's own refusal of the contract without the body being read. `challenge` is the `WWW-Authenticate` header,
/// which names how recently the owner must have signed in. `requestId` is the `X-Request-ID` header.
package func refusal(
    status: UInt16, contract served: String?, declaredCode: String? = nil, location: String?, retryAfter: String?,
    challenge: String? = nil, requestId: String?, origin: String, write: Bool, body: () async -> String
) async -> MarfaError? {
    if (300..<400).contains(status) {
        return .redirected(
            origin: origin, status: status, location: location,
            message: "\(origin) answered \(status) redirecting the request, which is never followed",
            server: ServerAnswer(status: status, code: nil, details: nil, requestId: requestId))
    }
    let expected = UInt64(marfaContractVersion)
    let success = (200..<300).contains(status)
    switch served {
    case String(expected)?:
        if success { return nil }
    case nil where !success:
        let text = await body()
        return .unnamed(
            status: status,
            message: "\(origin) answered \(status) naming no contract, taken as from something in front of the "
                + "server" + (text.isEmpty ? "" : ": \(text.prefix(200))"),
            server: ServerAnswer(status: status, code: nil, details: nil, requestId: requestId))
    default:
        let named = served.map { "contract \($0)" } ?? "no contract"
        let declined = status == 412 && declaredCode == "contract_mismatch"
        return .contractMismatch(
            served: served, expected: expected, status: status, writeSent: write && !declined,
            message: "\(origin) answered \(status) naming \(named), and this build speaks contract \(expected)"
                + (declined ? ". The server refused this request before it acted" : ""),
            server: ServerAnswer(
                status: status, code: declined ? declaredCode : nil, details: nil, requestId: requestId))
    }
    let text = await body()
    let refused = RefusalBody(text)
    let code = refused?.code ?? "unknown"
    let message = refused?.message ?? String(text.prefix(200))
    let shown = message.isEmpty ? "\(origin) answered \(status)" : message
    let answer = ServerAnswer(status: status, code: refused?.code, details: refused?.details, requestId: requestId)
    switch status {
    case 400 where code == "unknown_type": return .unknownType(message: shown, server: answer)
    case 412 where code == "contract_mismatch":
        return .contractMismatch(
            served: served, expected: expected, status: status, writeSent: false,
            message: "\(origin) refused the request before it acted: \(shown)", server: answer)
    case 400, 422: return .validation(code: code, message: shown, details: nil, server: answer)
    case 401 where code == "insufficient_user_authentication":
        return .confirmationRequired(maxAgeSeconds: maxAge(challenge), message: shown, server: answer)
    case 401: return .unauthorized(code: code, message: shown, server: answer)
    case 403 where code == "app_sign_in_required":
        return .appSignInRequired(
            message: "Do this from an app you signed in to. An API key cannot do it.", server: answer)
    case 403: return .forbidden(code: code, message: shown, server: answer)
    case 404: return .notFound(code: code, message: shown, server: answer)
    case 409 where code == "version_conflict": return .versionConflict(message: shown, server: answer)
    case 409 where code == "instance_changed": return .instanceChanged(message: shown, server: answer)
    case 429:
        return .rateLimited(
            code: code, message: shown, retryAfterSeconds: retryAfter.flatMap { UInt64($0) }, server: answer)
    default: return .server(status: status, code: code, message: shown, details: answer.details, server: answer)
    }
}

/// The `max_age` a `WWW-Authenticate: Bearer error="insufficient_user_authentication", max_age="300"` challenge names.
func maxAge(_ challenge: String?) -> UInt64? {
    guard let challenge, let found = challenge.range(of: "max_age=") else { return nil }
    let digits = challenge[found.upperBound...].drop { $0 == "\"" }.prefix { $0.isASCII && $0.isNumber }
    return UInt64(digits)
}

/// A refusal's `{"error": {...}}` body, where it has one: the `code`, the `message` and the `details`, which say what
/// the message alone cannot, such as which settings still name a type.
private struct RefusalBody {
    let code: String
    let message: String
    let details: JSONValue?

    private struct Envelope: Decodable {
        struct Error: Decodable {
            let code: String
            let message: String?
            let details: JSONValue?
        }
        let error: Error
    }

    init?(_ text: String) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else { return nil }
        code = envelope.error.code
        message = envelope.error.message ?? ""
        details = envelope.error.details
    }
}

/// The ``MarfaError`` a failure to send stands for, or `nil` for one that is not about the connection.
package func connectionFailure(_ error: any Error, origin: String) -> MarfaError? {
    if let error = error as? MarfaError { return error }
    if error is CancellationError { return .canceled(message: "the request to \(origin) was canceled") }
    guard let error = error as? URLError else { return nil }
    switch error.code {
    case .cancelled: return .canceled(message: "the request to \(origin) was canceled")
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
        return .noConnection(message: "the device is offline, so nothing was sent to \(origin)")
    case .timedOut: return .network(message: "\(origin) did not answer in time")
    default: return .network(message: "\(origin) could not be reached: \(error.localizedDescription)")
    }
}

extension Server {
    /// Sends one request to the server and answers the body of a success, as the generated client does: the key, or
    /// the sign-in's access token, is sent as a bearer token; a refused access token is renewed once and the request
    /// sent again; a redirect is never followed; and every failure throws a ``MarfaError``.
    ///
    /// `timeout` limits each try of the call, renewal and second request included: once it passes, the call throws
    /// ``MarfaError/network(message:)`` and the request is canceled. A renewal already under way finishes on its own,
    /// so the token it keeps is never lost. When the server asks the owner to confirm it is them, the owner's time at
    /// the sheet counts toward no limit, and the call sent again gets the whole limit.
    func send(
        _ method: String, _ path: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
        body: Data? = nil, timeout: Duration
    ) async throws(MarfaError) -> Data {
        let mark = confirmationMark()
        let token = try currentToken()
        do {
            return try await timed(
                method, path, query: query, headers: headers, body: body, timeout: timeout, token: token)
        } catch .confirmationRequired(let maxAge, let message, let answer) {
            // The sheet waits for a person, so the call's time limit starts again once it closes.
            let confirmed = try await confirmedToken(
                since: mark,
                challenge: .confirmationRequired(maxAgeSeconds: maxAge, message: message, server: answer))
            return try await timed(
                method, path, query: query, headers: headers, body: body, timeout: timeout, token: confirmed)
        }
    }

    private func timed(
        _ method: String, _ path: String, query: [URLQueryItem], headers: [String: String], body: Data?,
        timeout: Duration, token: String
    ) async throws(MarfaError) -> Data {
        let first = FirstAnswer<Result<Data, MarfaError>>()
        let work = Task {
            do throws(MarfaError) {
                let data = try await unlimited(
                    method, path, query: query, headers: headers, body: body, timeout: timeout, token: token)
                first.answer(.success(data))
            } catch {
                first.answer(.failure(error))
            }
        }
        let origin = origin
        let timer = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            first.answer(.failure(.network(message: "\(origin) did not answer within \(timeout)")))
            work.cancel()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            await first.value
        } onCancel: {
            first.answer(.failure(.canceled(message: "the request to \(origin) was canceled")))
            work.cancel()
        }.get()
    }

    private func unlimited(
        _ method: String, _ path: String, query: [URLQueryItem], headers: [String: String], body: Data?,
        timeout: Duration, token: String
    ) async throws(MarfaError) -> Data {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw .invalid(message: "the address of \(origin) is not one a request can be made to")
        }
        var base = components.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        components.percentEncodedPath = base + path
        components.percentEncodedQuery =
            query.isEmpty
            ? nil
            : query.map { "\(Server.queryPart($0.name))=\(Server.queryPart($0.value ?? ""))" }.joined(separator: "&")
        guard let target = components.url else {
            throw .invalid(message: "the request to \(origin) could not be made")
        }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        ContractHeader.apply(to: &request, path: path)

        let connection = Connection(base: signInSession, timeout: timeout)
        let write = method != "GET" && method != "HEAD"
        let first = try await exchange(request, token, connection)
        guard let refused = await refusal(first, write: write) else { return first.1 }
        guard case .unauthorized = refused, let renewed = try await renewedToken(refused: token) else { throw refused }
        let again = try await exchange(request, renewed, connection)
        if let refusedAgain = await refusal(again, write: write) { throw refusedAgain }
        return again.1
    }

    private func exchange(
        _ request: URLRequest, _ token: String, _ connection: Connection
    ) async throws(MarfaError) -> (HTTPURLResponse, Data) {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await connection.session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw MarfaError.network(message: "\(origin) did not answer with http")
            }
            return (response, data)
        } catch {
            throw connectionFailure(error, origin: origin)
                ?? .network(message: "\(origin) could not be reached: \(error.localizedDescription)")
        }
    }

    private func refusal(_ answer: (HTTPURLResponse, Data), write: Bool) async -> MarfaError? {
        let (response, data) = answer
        return await Marfa.refusal(
            status: UInt16(clamping: response.statusCode),
            contract: response.value(forHTTPHeaderField: ContractHeader.name),
            declaredCode: response.value(forHTTPHeaderField: "X-Error-Code"),
            location: response.value(forHTTPHeaderField: "Location"),
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            challenge: response.value(forHTTPHeaderField: "WWW-Authenticate"),
            requestId: response.value(forHTTPHeaderField: "X-Request-ID"), origin: origin, write: write
        ) { String(decoding: data.prefix(64 * 1024), as: UTF8.self) }
    }

    /// A path segment as a request carries it: an identifier is one segment, so a `/` in it is escaped too.
    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: segmentCharacters) ?? value
    }

    /// A query name or value as a request carries it. `URLQueryItem` leaves `+` as it is, which a server reads as a
    /// space, so this escapes it with the separators.
    static func queryPart(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryCharacters) ?? value
    }

    private static let queryCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return allowed
    }()

    private static let segmentCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return allowed
    }()
}

/// The first of several answers to arrive, which a waiter takes whether it starts waiting before or after.
private final class FirstAnswer<Value: Sendable>: Sendable {
    private enum State {
        case waiting
        case listening(CheckedContinuation<Value, Never>)
        case answered(Value)
        case taken
    }

    private let state = Mutex(State.waiting)

    func answer(_ value: Value) {
        let listener = state.withLock { state -> CheckedContinuation<Value, Never>? in
            switch state {
            case .waiting:
                state = .answered(value)
                return nil
            case .listening(let continuation):
                state = .taken
                return continuation
            case .answered, .taken: return nil
            }
        }
        listener?.resume(returning: value)
    }

    var value: Value {
        get async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Value? in
                    guard case .answered(let value) = state else {
                        state = .listening(continuation)
                        return nil
                    }
                    state = .taken
                    return value
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}

/// Where a request learns which contract this build was made for.
///
/// Every request carries it but a read of the server's root or of `/health`, so a build made for another contract
/// can still learn which one a server speaks. A server refuses any other request that names a different contract
/// before it acts.
package enum ContractHeader {
    package static let name = "X-Marfa-Contract"

    /// The value to send with a request, or `nil` for one that sends none.
    ///
    /// `path` is the request's path under the server's own address, with or without its query.
    package static func value(method: String, path: String) -> String? {
        let path = path.prefix { $0 != "?" }
        if method == "GET", path.isEmpty || path == "/" || path == "/health" { return nil }
        return String(marfaContractVersion)
    }

    static func apply(to request: inout URLRequest, path: String) {
        request.setValue(nil, forHTTPHeaderField: name)
        if let value = value(method: request.httpMethod ?? "GET", path: path) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }
}
