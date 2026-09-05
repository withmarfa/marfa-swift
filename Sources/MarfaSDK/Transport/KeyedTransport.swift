import Foundation

/// A transport that stamps one `Idempotency-Key` onto every write it carries.
///
/// **This exists so the key cannot be forgotten rather than so it is easy to
/// remember.** The replay switch has sixteen transport calls across as many
/// mutation kinds, and a seventeenth kind added later would compile, ship and
/// silently send no key — the failure would be invisible until a lost response
/// duplicated somebody's data. Wrapping the transport once, at the top of the
/// replay, means every call inside it carries the key by construction and a
/// new kind inherits that without anyone noticing it needed to.
///
/// `nil` forwards unchanged, which is what a row enqueued before keys existed
/// gets. Such a row replays exactly as it always did.
struct KeyedTransport: Transport {
    let base: any Transport
    let key: String?

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        try await base.request(
            method: method, path: path, body: body, query: query, idempotencyKey: key
        )
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?,
        idempotencyKey: String?
    ) async throws -> T {
        // The caller's key wins over the wrapper's, so an explicit one is
        // never silently replaced. Nothing does this today; the alternative
        // is a wrapper that quietly ignores its caller.
        try await base.request(
            method: method, path: path, body: body, query: query,
            idempotencyKey: idempotencyKey ?? key
        )
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        try await base.requestWithConflict(
            method: method, path: path, body: body, query: query, idempotencyKey: key
        )
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?,
        idempotencyKey: String?
    ) async throws -> ConflictResult<T> {
        try await base.requestWithConflict(
            method: method, path: path, body: body, query: query,
            idempotencyKey: idempotencyKey ?? key
        )
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        try await base.rawRequest(
            method: method, path: path, body: body, contentType: contentType, query: query
        )
    }

    func rawUpload(
        method: HTTPMethod,
        path: String,
        body: Data,
        contentType: String?,
        query: [(String, String)]?,
        onBytesSent: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        try await base.rawUpload(
            method: method, path: path, body: body, contentType: contentType,
            query: query, onBytesSent: onBytesSent
        )
    }

    func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        base.eventStream(path: path, query: query, lastEventID: lastEventID)
    }
}
