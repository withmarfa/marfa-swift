import Foundation
import CryptoKit

/// Blobs API namespace. Manages binary file uploads and downloads.
///
/// In **synced mode** (`MarfaClient.synced(...)`) uploads are queued for
/// offline-resilient replay. `upload(data:mimeType:)` computes the SHA-256
/// content hash locally (matching the server's content-addressed store),
/// persists the bytes in the local database, and returns a
/// ``BlobUploadResponse`` immediately so callers can proceed to create items
/// and edges that reference the blob before it reaches the server. The sync
/// engine drains the queued upload when connectivity is available.
///
/// In **network-only mode** (`MarfaClient(url:apiKey:)`) `upload` hits the
/// transport directly, identical to the previous behavior.
///
/// A client created via ``MarfaClient/local(path:)`` has no live server;
/// calling `upload`, `download`, `exists`, or `presignedURL` throws
/// ``LocalModeUnsupportedError``.
public struct BlobsNamespace: Sendable {

    let transport: any Transport
    let apiBaseURL: URL
    let cdnBaseURL: URL?
    let mutationQueue: MutationQueue?
    let localStore: LocalStore?

    /// `true` when this namespace is attached to a pure-local client. When
    /// set, every method except ``url(hash:)`` throws before touching the
    /// transport.
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Uploads binary data as a blob.
    ///
    /// In synced mode the upload is queued for offline-resilient replay:
    /// the SHA-256 hash is computed locally and returned immediately, along
    /// with the known MIME type and byte count. The actual upload happens
    /// when the sync engine next drains the mutation queue. If the upload
    /// ultimately fails permanently (e.g. the server rejects the content
    /// type), a ``SyncEvent/mutationDropped`` event is emitted on the sync
    /// engine's `events` stream. In synced mode pass `nil` for `onProgress`
    /// — progress for queued uploads arrives via ``BlobUploadProgressQuery``
    /// on the reactive layer, not via this callback.
    ///
    /// In network-only mode the upload is performed synchronously and any
    /// error is thrown immediately, as before. `onProgress` (if non-nil)
    /// is invoked one or more times during the request body's transfer
    /// with `(bytesSent, totalBytes)` pairs. Callback runs on the
    /// `URLSession` delegate queue — hop to the main actor yourself if
    /// you're updating SwiftUI state from it.
    public func upload(
        data: Data,
        mimeType: String,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> BlobUploadResponse {
        // **A client with no server keeps the bytes rather than refusing
        // them.** This used to be an `ensureRemote` refusal, which left the
        // read-through cache able to hold only what an earlier synced session
        // had put there — so a pure-local app could open a file and never make
        // one, and no `core.file.*` item on such a device could point at
        // anything. The store has had the table all along; what was missing
        // was a door into it.
        //
        // Owned rather than cached, because on this client the bytes are the
        // only copy: nothing can fetch them back, so neither the eviction rule
        // nor the size bound may drop them.
        //
        // **The hash is the server's hash.** It is computed from the bytes by
        // the same function the synced path uses, so a store that later gains
        // a server addresses the same blob the server would.
        if isLocalMode {
            guard let localStore else {
                throw LocalModeUnsupportedError(operation: "blobs.upload")
            }
            let hash = sha256Hash(of: data)
            try await localStore.ownBlob(hash: hash, data: data, mimeType: mimeType)
            return BlobUploadResponse(hash: hash, mimeType: mimeType, size: data.count)
        }

        if let queue = mutationQueue {
            // Synced mode: compute hash locally, queue, return immediately.
            let hash = sha256Hash(of: data)
            try await queue.enqueueBlobUpload(hash: hash, data: data, mimeType: mimeType)
            // Cached at the moment it is made, not when it reaches the server.
            // A person who saves a picture and opens it a second later is not
            // waiting on a drain, and the bytes are already in hand.
            try? await localStore?.cacheBlob(hash: hash, data: data, mimeType: mimeType)
            return BlobUploadResponse(hash: hash, mimeType: mimeType, size: data.count)
        }

        // Network-only mode: upload synchronously.
        let (responseData, response): (Data, HTTPURLResponse)
        if let onProgress {
            (responseData, response) = try await transport.rawUpload(
                method: .post, path: "/blobs", body: data,
                contentType: mimeType, query: nil,
                onBytesSent: onProgress
            )
        } else {
            (responseData, response) = try await transport.rawRequest(
                method: .post, path: "/blobs", body: data,
                contentType: mimeType, query: nil
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw parseMarfaError(data: responseData, statusCode: response.statusCode)
        }

        do {
            return try JSONDecoder().decode(BlobUploadResponse.self, from: responseData)
        } catch {
            throw ResponseDecodingError(error)
        }
    }

    // MARK: - Private helpers

    /// Computes the SHA-256 content hash in the `"sha256:<hex>"` format the
    /// server uses for content-addressed blob storage.
    private func sha256Hash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    /// Downloads a blob by its content hash. Returns the raw data and MIME type.
    ///
    /// **Served from the device when the device has it.** A blob is addressed
    /// by the hash of its own bytes, so a cached copy can never be the wrong
    /// answer — there is no version to be behind and no staleness to reason
    /// about. That is what makes a read-through cache correct here rather than
    /// merely fast, and it is why this works with no server at all.
    ///
    /// **That holds for the bytes and not for the MIME type**, which the hash
    /// does not cover and which reaches this cache from three authorities: the
    /// caller who uploaded, the outbound row, and the server's `Content-Type`.
    /// A later write refreshes it, so the answer converges on whatever spoke
    /// last rather than on whoever got there first.
    ///
    /// A client with a store keeps what it uploads and what it fetches, under
    /// a least-recently-used bound. Without a store, every call is a fetch, as
    /// before. In pure-local mode this is the whole of it: ``upload(data:mimeType:onProgress:)``
    /// writes the bytes into the same store as owned, and there is no server
    /// behind the cache to reach for a hash it does not hold.
    public func download(hash: String) async throws -> (Data, String) {
        let cleanHash = hash.hasPrefix("sha256:") ? hash : "sha256:\(hash)"

        if let cached = try? await localStore?.cachedBlob(hash: cleanHash) {
            return (cached.data, cached.mimeType)
        }
        // Only now does this need a server. A pure-local client that holds the
        // blob has already returned; one that does not is being asked for
        // bytes that exist nowhere it can reach.
        try ensureRemote("blobs.download")

        let (data, response) = try await transport.rawRequest(
            method: .get, path: "/blobs/\(cleanHash)", body: nil,
            contentType: nil, query: nil
        )

        guard (200..<300).contains(response.statusCode) else {
            throw parseMarfaError(data: data, statusCode: response.statusCode)
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        try? await localStore?.cacheBlob(hash: cleanHash, data: data, mimeType: contentType)
        return (data, contentType)
    }

    /// Checks whether a blob exists without downloading it.
    public func exists(hash: String) async throws -> Bool {
        try ensureRemote("blobs.exists")
        let cleanHash = hash.hasPrefix("sha256:") ? hash : "sha256:\(hash)"
        let (_, response) = try await transport.rawRequest(
            method: .head, path: "/blobs/\(cleanHash)", body: nil,
            contentType: nil, query: nil
        )
        return response.statusCode == 200
    }

    /// Returns a URL for the blob. Uses the CDN base URL if configured,
    /// otherwise falls back to the API base URL.
    public func url(hash: String) -> URL {
        let cleanHash = hash.hasPrefix("sha256:") ? hash : "sha256:\(hash)"
        let base = cdnBaseURL ?? apiBaseURL
        return base.appendingPathComponent("blobs/\(cleanHash)")
    }

    /// Gets a presigned download URL for a blob (S3 backend only).
    public func presignedURL(hash: String, ttl: Int? = nil) async throws -> PresignedURLResponse {
        try ensureRemote("blobs.presignedURL")
        let cleanHash = hash.hasPrefix("sha256:") ? hash : "sha256:\(hash)"
        var query: [(String, String)] = []
        if let ttl { query.append(("ttl", String(ttl))) }
        return try await transport.request(
            method: .get, path: "/blobs/\(cleanHash)/url", body: nil,
            query: query.isEmpty ? nil : query
        )
    }
}
