import Foundation
import HTTPTypes
import Marfa
import MarfaTypes
import OpenAPIRuntime

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
        let mark = server.confirmationMark()
        let token = try server.currentToken()
        let write = request.method != .get && request.method != .head
        let sent = try await send(request, body, baseURL, token, next)
        if let refused = await refusal(sent, origin: origin, write: write) {
            // A body that can be read once has gone with the refused request.
            let again: String?
            switch refused {
            case .unauthorized:
                // A wrong current password is answered like a refused token, and sending it again would count it twice.
                guard operationID != "replaceOwnerPassword" else { throw refused }
                again = try await server.renewedToken(refused: token)
                guard body?.iterationBehavior != .single else { throw refused }
            case .confirmationRequired:
                guard body?.iterationBehavior != .single else { throw refused }
                again = try await server.confirmedToken(since: mark, challenge: refused)
            default: again = nil
            }
            guard let again else { throw refused }
            let second = try await send(request, body, baseURL, again, next)
            if let refusedAgain = await refusal(second, origin: origin, write: write) { throw refusedAgain }
            return second
        }
        return sent
    }

    private func send(
        _ request: HTTPRequest, _ body: HTTPBody?, _ baseURL: URL, _ token: String,
        _ next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws(MarfaError) -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        request.headerFields[contractHeader] = ContractHeader.value(
            method: request.method.rawValue,
            path: request.path ?? "")
        do {
            return try await next(request, body, baseURL)
        } catch {
            let cause = (error as? ClientError)?.underlyingError ?? error
            throw connectionFailure(cause, origin: server.origin)
                ?? .network(message: "\(server.origin) could not be reached: \(cause.localizedDescription)")
        }
    }
}

/// The error an answer stands for, or `nil` for a success from a server speaking this build's contract.
func refusal(_ answer: (HTTPResponse, HTTPBody?), origin: String, write: Bool) async -> MarfaError? {
    let (response, body) = answer
    return await Marfa.refusal(
        status: UInt16(clamping: response.status.code),
        contract: response.headerFields.first { $0.name.canonicalName == "x-marfa-contract" }?.value,
        declaredCode: response.headerFields[xErrorCode],
        location: response.headerFields[.location], retryAfter: response.headerFields[.retryAfter],
        challenge: response.headerFields[.wwwAuthenticate], requestId: response.headerFields[requestIdHeader],
        origin: origin, write: write
    ) { await read(body) }
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

private let contractHeader = headerName(ContractHeader.name)
private let xErrorCode = headerName("X-Error-Code")
private let requestIdHeader = headerName("X-Request-ID")

/// A header name written in this file, which is always a valid one.
private func headerName(_ name: String) -> HTTPField.Name {
    guard let field = HTTPField.Name(name) else { preconditionFailure("\(name) is not a header name") }
    return field
}
