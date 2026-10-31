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
        location: response.headerFields[.location], retryAfter: response.headerFields[.retryAfter], origin: origin,
        write: write
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
