import Foundation
import CryptoKit

/// Blobs API namespace. Manages binary file uploads and downloads.
///
/// In **synced mode** (`MymeClient.synced(...)`) uploads are queued for
/// offline-resilient replay. `upload(data:mimeType:)` computes the SHA-256
/// content hash locally (matching the server's content-addressed store),
/// persists the bytes in the local database, and returns a
/// ``BlobUploadResponse`` immediately so callers can proceed to create items
/// and edges that reference the blob before it reaches the server. The sync
/// engine drains the queued upload when connectivity is available.
///
/// In **network-only mode** (`MymeClient(url:apiKey:)`) `upload` hits the
/// transport directly, identical to the previous behaviour.
///
/// A client created via ``MymeClient/local(path:)`` has no live server;
/// calling `upload`, `download`, `exists`, or `presignedURL` throws
/// ``LocalModeUnsupportedError``.
public struct BlobsNamespace: Sendable {

    let transport: any Transport
    let apiBaseURL: URL
    let cdnBaseURL: URL?
    let mutationQueue: MutationQueue?

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
    /// engine's `events` stream.
    ///
    /// In network-only mode the upload is performed synchronously and any
    /// error is thrown immediately, as before.
    public func upload(data: Data, mimeType: String) async throws -> BlobUploadResponse {
        try ensureRemote("blobs.upload")

        if let queue = mutationQueue {
            // Synced mode: compute hash locally, queue, return immediately.
            let hash = sha256Hash(of: data)
            try await queue.enqueueBlobUpload(hash: hash, data: data, mimeType: mimeType)
            return BlobUploadResponse(hash: hash, mimeType: mimeType, size: data.count)
        }

        // Network-only mode: upload synchronously.
        let (responseData, response) = try await transport.rawRequest(
            method: .post, path: "/blobs", body: data,
            contentType: mimeType, query: nil
        )

        guard (200..<300).contains(response.statusCode) else {
            throw parseMymeError(data: responseData, statusCode: response.statusCode)
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
    public func download(hash: String) async throws -> (Data, String) {
        try ensureRemote("blobs.download")
        let cleanHash = hash.hasPrefix("sha256:") ? hash : "sha256:\(hash)"
        let (data, response) = try await transport.rawRequest(
            method: .get, path: "/blobs/\(cleanHash)", body: nil,
            contentType: nil, query: nil
        )

        guard (200..<300).contains(response.statusCode) else {
            throw parseMymeError(data: data, statusCode: response.statusCode)
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
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
