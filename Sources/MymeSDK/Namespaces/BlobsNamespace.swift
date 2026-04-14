import Foundation

/// Blobs API namespace. Manages binary file uploads and downloads.
public struct BlobsNamespace: Sendable {

    let transport: any Transport
    let apiBaseURL: URL
    let cdnBaseURL: URL?

    /// Uploads binary data as a blob.
    public func upload(data: Data, mimeType: String) async throws -> BlobUploadResponse {
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

    /// Downloads a blob by its content hash. Returns the raw data and MIME type.
    public func download(hash: String) async throws -> (Data, String) {
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
        let cleanHash = hash.hasPrefix("sha256:") ? hash : "sha256:\(hash)"
        var query: [(String, String)] = []
        if let ttl { query.append(("ttl", String(ttl))) }
        return try await transport.request(
            method: .get, path: "/blobs/\(cleanHash)/url", body: nil,
            query: query.isEmpty ? nil : query
        )
    }
}
