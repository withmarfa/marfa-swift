import Foundation

/// Base error class for Myme API errors.
///
/// Subclasses map to specific HTTP status codes. Use pattern matching
/// to handle specific error types:
///
///     do {
///         let item = try await client.items.get(id: "...")
///     } catch let error as NotFoundError {
///         print("Item not found: \(error.message)")
///     } catch let error as MymeError {
///         print("API error \(error.status): \(error.message)")
///     }
open class MymeError: Error, @unchecked Sendable {
    /// The error code from the server (e.g., "not_found", "validation_error").
    public let code: String

    /// The HTTP status code.
    public let status: Int

    /// Human-readable error message.
    public let message: String

    /// Additional error details from the server.
    public let details: [String: JSONValue]?

    public init(code: String, message: String, status: Int, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.details = details
    }
}

extension MymeError: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - Specific Error Types

/// 404 — The requested resource does not exist.
public final class NotFoundError: MymeError, @unchecked Sendable {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "not_found", message: message, status: 404, details: details)
    }
}

/// 400 — The request failed validation.
public final class ValidationError: MymeError, @unchecked Sendable {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "validation_error", message: message, status: 400, details: details)
    }
}

/// 401 — Invalid or expired credentials.
public final class UnauthorizedError: MymeError, @unchecked Sendable {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "unauthorized", message: message, status: 401, details: details)
    }
}

/// 403 — Valid credentials but insufficient permissions.
public final class ForbiddenError: MymeError, @unchecked Sendable {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "forbidden", message: message, status: 403, details: details)
    }
}

/// 409 — Version conflict with resolution data.
public final class ConflictError: MymeError, @unchecked Sendable {
    /// The server's current state.
    public let current: ConflictSnapshot

    /// The last common ancestor state.
    public let ancestor: ConflictSnapshot

    /// Fields that differ between the client patch and server state.
    public let conflictingFields: [String]

    /// The properties the client attempted to write.
    public let clientPatch: [String: JSONValue]

    public init(
        current: ConflictSnapshot,
        ancestor: ConflictSnapshot,
        conflictingFields: [String],
        clientPatch: [String: JSONValue]
    ) {
        self.current = current
        self.ancestor = ancestor
        self.conflictingFields = conflictingFields
        self.clientPatch = clientPatch
        super.init(
            code: "version_conflict",
            message: "Version conflict on fields: \(conflictingFields.joined(separator: ", "))",
            status: 409
        )
    }
}

// MARK: - Local Mode

/// 501 — Operation requires a live server connection and is not available on a
/// pure-local ``MymeClient`` created with ``MymeClient/local(path:)``.
/// Blob uploads and downloads throw this when called on a local-only client.
public final class LocalModeUnsupportedError: MymeError, @unchecked Sendable {
    /// Name of the operation that was attempted (e.g. `"blobs.upload"`).
    public let operation: String

    public init(operation: String) {
        self.operation = operation
        super.init(
            code: "local_mode_unsupported",
            message:
                "\(operation) requires a live server connection. Use MymeClient.synced(...) or MymeClient(url:apiKey:) instead.",
            status: 501
        )
    }
}

// MARK: - Network Error

/// Transport-level failure (no connectivity, timeout, DNS, etc.).
public final class NetworkError: MymeError, @unchecked Sendable {
    /// The underlying transport error.
    public let underlyingError: Error

    public init(_ error: Error) {
        self.underlyingError = error
        super.init(
            code: "network_error",
            message: error.localizedDescription,
            status: 0
        )
    }
}

/// Response body could not be decoded into the expected type.
public final class ResponseDecodingError: MymeError, @unchecked Sendable {
    /// The underlying decoding error.
    public let underlyingError: Error

    public init(_ error: Error) {
        self.underlyingError = error
        super.init(
            code: "decoding_error",
            message: "Failed to decode response: \(error.localizedDescription)",
            status: 0
        )
    }
}

// MARK: - Wire Types

/// Structured error response from the Myme server.
struct APIErrorResponse: Codable, Sendable {
    let error: ErrorInfo
}

/// Error detail block within an API error response.
struct ErrorInfo: Codable, Sendable {
    let code: String
    let status: Int?
    let message: String?
    let details: [String: JSONValue]?
}
