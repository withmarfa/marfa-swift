import Foundation
import HTTPTypes
import Marfa
import MarfaTypes
import OpenAPIRuntime

/// The session a client's requests go through, closed when the last client using it is released.
final class Connection: Sendable {
    let session: URLSession

    init(base: URLSession?, timeout: Duration) {
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

/// Sends the server's credential with each request, and reads every answer that is not a success as the
/// working copy reads it.
struct Access: ClientMiddleware {
    let server: Server
    /// Held so the session lives as long as the client.
    let connection: Connection

    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let origin = server.origin
        let token = try server.currentToken()
        let write = request.method != .get && request.method != .head
        let sent = try await send(request, body, baseURL, token, next)
        if let refused = await refusal(sent, origin: origin, write: write) {
            guard case .unauthorized = refused, let renewed = try await server.renewedToken(refused: token) else {
                throw refused
            }
            // A body that can be read once has gone with the refused request.
            guard body?.iterationBehavior != .single else { throw refused }
            let again = try await send(request, body, baseURL, renewed, next)
            if let refusedAgain = await refusal(again, origin: origin, write: write) { throw refusedAgain }
            return again
        }
        return sent
    }

    private func send(
        _ request: HTTPRequest, _ body: HTTPBody?, _ baseURL: URL, _ token: String,
        _ next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws(MarfaError) -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        do {
            return try await next(request, body, baseURL)
        } catch {
            let cause = (error as? ClientError)?.underlyingError ?? error
            throw failure(cause, origin: server.origin)
                ?? .network(message: "\(server.origin) could not be reached: \(cause.localizedDescription)")
        }
    }
}

/// The error an answer stands for, or `nil` for a success from a server speaking this build's contract.
func refusal(_ answer: (HTTPResponse, HTTPBody?), origin: String, write: Bool) async -> MarfaError? {
    let (response, body) = answer
    let status = UInt16(clamping: response.status.code)
    if (300..<400).contains(status) {
        return .redirected(
            origin: origin, status: status, location: response.headerFields[.location],
            message: "\(origin) answered \(status) redirecting the request, which is never followed")
    }
    let served = response.headerFields.first { $0.name.canonicalName == "x-marfa-contract" }?.value
    let expected = UInt64(marfaContractVersion)
    let success = (200..<300).contains(status)
    switch served {
    case String(expected)?:
        if success { return nil }
    case nil where !success:
        let text = await read(body)
        return .unnamed(
            status: status,
            message: "\(origin) answered \(status) naming no contract, taken as from something in front of the "
                + "server" + (text.isEmpty ? "" : ": \(text.prefix(200))"))
    default:
        let named = served.map { "contract \($0)" } ?? "no contract"
        return .contractMismatch(
            served: served, expected: expected, status: status, writeSent: write,
            message: "\(origin) answered \(status) naming \(named), and this build speaks contract \(expected)")
    }
    let text = await read(body)
    let (code, message) = refusalBody(text) ?? ("unknown", String(text.prefix(200)))
    let shown = message.isEmpty ? "\(origin) answered \(status)" : message
    switch status {
    case 400 where code == "unknown_type": return .unknownType(message: shown)
    case 400, 422: return .validation(code: code, message: shown)
    case 401: return .unauthorized(code: code, message: shown)
    case 403: return .forbidden(code: code, message: shown)
    case 404: return .notFound(code: code, message: shown)
    case 409 where code == "version_conflict": return .versionConflict(message: shown)
    case 409 where code == "instance_changed": return .instanceChanged(message: shown)
    case 429:
        return .rateLimited(
            code: code, message: shown,
            retryAfterSeconds: response.headerFields[.retryAfter].flatMap { UInt64($0) })
    default: return .server(status: status, code: code, message: shown)
    }
}

/// The `code` and `message` of a refusal's `{"error": {...}}` body, where it has one.
///
/// A refusal's `details` follow the message as JSON, since they say what the message alone cannot, such as which
/// settings still name a type.
private func refusalBody(_ text: String) -> (code: String, message: String)? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let error = object["error"] as? [String: Any], let code = error["code"] as? String
    else { return nil }
    var message = error["message"] as? String ?? ""
    if let details = error["details"] as? [String: Any], !details.isEmpty,
        let data = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
        let json = String(data: data, encoding: .utf8)
    {
        message += (message.isEmpty ? "" : " ") + "Details: \(json)"
    }
    return (code, message)
}

/// Up to the first 64 KiB of a refusal's body as text; a body that fails part way is read as far as it got.
private func read(_ body: HTTPBody?) async -> String {
    guard let body else { return "" }
    let limit = 64 * 1024
    var data = Data()
    do {
        for try await chunk in body {
            data.append(contentsOf: chunk.prefix(limit - data.count))
            if data.count >= limit { break }
        }
    } catch {}
    return String(decoding: data, as: UTF8.self)
}

/// The ``MarfaError`` a failure to send stands for, or `nil` for one that is not about the connection.
func failure(_ error: any Error, origin: String) -> MarfaError? {
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
