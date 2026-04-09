import Foundation

/// Response from uploading a blob.
public struct BlobUploadResponse: Codable, Sendable {
    public let hash: String
    public let mimeType: String
    public let size: Int

    enum CodingKeys: String, CodingKey {
        case hash, size
        case mimeType = "mime_type"
    }
}

/// Response from requesting a presigned blob URL.
public struct PresignedURLResponse: Codable, Sendable {
    public let url: String
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case url
        case expiresIn = "expires_in"
    }
}
