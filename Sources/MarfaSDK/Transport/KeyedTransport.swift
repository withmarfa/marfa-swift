import Foundation

/// A transport that stamps one `Idempotency-Key` onto every write it carries.
///
/// **This exists so the key cannot be forgotten rather than so it is easy to
/// remember.** The replay switch has sixteen transport calls across as many
/// mutation kinds, and a seventeenth kind added later would compile, ship and
/// silently send no key — the failure would be invisible until a lost response
/// duplicated somebody's data. Wrapping the transport once, at the top of the
/// replay, means every JSON call inside it carries the key by construction and
/// a new kind inherits that without anyone noticing it needed to.
///
/// **Two doors are exceptions and neither is guarded by anything but this
/// sentence.** ``rawRequest(method:path:body:contentType:query:)`` and
/// ``rawUpload(...)`` forward without a key, because the protocol has no keyed
/// form of either. A blob upload wants that — `POST /blobs` takes no key and
/// the replay tells "already there" from "lost" with a `HEAD` probe instead.
/// A bulk action does not: it reaches the server through `rawRequest`, so the
/// `.bulkAction` replay arm is exactly the "seventeenth kind that compiles,
/// ships and sends no key" this wrapper was built to prevent. Keying it means
/// giving the protocol a keyed `rawRequest`, not adding a call here.
///
/// `nil` forwards unchanged, which is what a row enqueued before keys existed
/// gets. Such a row replays exactly as it always did.
struct KeyedTransport: Transport {
    let base: any Transport
    let key: String?

    /// A key is only ever stamped on a **write**.
    ///
    /// The wrapper covers a whole replay, and a replay is not only writes: a
    /// bulk action posts once and then polls the job with `GET`s through the
    /// same transport. Keying a read is never right, and here it would be
    /// silently total — the server would answer every poll with the first
    /// poll's stored body, so the job would never be observed finishing and
    /// the runner would spin to its timeout. Harmless today only because that
    /// route is not one the server keys, which is not a property this file
    /// should depend on.
    private func keyFor(_ method: HTTPMethod) -> String? {
        HTTPMethod.isWrite(method) ? key : nil
    }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        try await base.request(
            method: method, path: path, body: body, query: query,
            idempotencyKey: keyFor(method)
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
            idempotencyKey: idempotencyKey ?? keyFor(method)
        )
    }

    /// **Forwards the caller's key rather than substituting the row's.** The
    /// conflict loop decides per attempt whether a key is safe — the first
    /// attempt is the one whose lost response matters, and a resolver-driven
    /// retry carries a different body that a keyed repeat would meet with a
    /// `422`. Stamping the row's key on every attempt here would take that
    /// decision away from the only code that can make it.
    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?,
        idempotencyKey: String?
    ) async throws -> ConflictResult<T> {
        try await base.requestWithConflict(
            method: method, path: path, body: body, query: query,
            idempotencyKey: idempotencyKey
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
