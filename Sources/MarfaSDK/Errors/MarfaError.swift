import Foundation

/// Base error class for Marfa API errors.
///
/// Subclasses map to specific HTTP status codes. Use pattern matching
/// to handle specific error types:
///
///     do {
///         let item = try await client.items.get(id: "...")
///     } catch let error as NotFoundError {
///         print("Item not found: \(error.message)")
///     } catch let error as MarfaError {
///         print("API error \(error.status): \(error.message)")
///     }
open class MarfaError: Error, @unchecked Sendable {
    /// Server error code (e.g. `"not_found"`, `"validation_error"`).
    public let code: String

    /// HTTP status code.
    public let status: Int

    public let message: String

    /// Additional structured detail from the server response.
    public let details: [String: JSONValue]?

    public init(code: String, message: String, status: Int, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.details = details
    }

    /// Whether this error is permanent — i.e., retrying the same request
    /// would produce the same failure. Used by ``SyncEngine`` to drop
    /// queued mutations that will never succeed (malformed IDs, validation
    /// failures, references to items the server no longer has) instead of
    /// replaying them on every sync cycle.
    ///
    /// Permanent: `400` (validation), `403` (forbidden), `404` (not found),
    /// and `version_bump_mismatch` (server-side semver-diff rejection at type
    /// registration). Transient: everything else — network failures, `5xx`,
    /// timeouts, `401` (credentials may be refreshed), `409` (resolvable via
    /// conflict strategy), `429` (rate-limited, caller should retry).
    public var isPermanent: Bool {
        if self is SchemaVersionMismatchError { return true }
        switch status {
        case 400, 403, 404: return true
        default: return false
        }
    }
}

extension MarfaError: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - Specific Error Types

/// 404 — resource does not exist.
public final class NotFoundError: MarfaError, @unchecked Sendable {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "not_found", message: message, status: 404, details: details)
    }
}

/// 400 — request failed validation.
public final class ValidationError: MarfaError, @unchecked Sendable {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "validation_error", message: message, status: 400, details: details)
    }
}

/// 401 — invalid or expired credentials.
public final class UnauthorizedError: MarfaError, @unchecked Sendable {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "unauthorized", message: message, status: 401, details: details)
    }
}

/// 403 — valid credentials but insufficient permissions.
public final class ForbiddenError: MarfaError, @unchecked Sendable {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "forbidden", message: message, status: 403, details: details)
    }
}

/// 409 — version conflict with resolution data.
public final class ConflictError: MarfaError, @unchecked Sendable {
    public let current: ConflictSnapshot
    public let ancestor: ConflictSnapshot
    public let conflictingFields: [String]
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

    /// Convenience initialiser for 409 conflicts without version-conflict
    /// snapshot data (e.g. `duplicate_id` from a `create_only` bulk
    /// outcome). Snapshot fields are populated with empty placeholders;
    /// consumers that need to distinguish should branch on `code` or use
    /// pattern-matching on a more specific subclass.
    public init(message: String, details: [String: JSONValue]? = nil) {
        self.current = ConflictSnapshot(properties: [:], version: 0)
        self.ancestor = ConflictSnapshot(properties: [:], version: 0)
        self.conflictingFields = []
        self.clientPatch = [:]
        super.init(
            code: "duplicate_id",
            message: message,
            status: 409,
            details: details
        )
    }
}

// MARK: - Schema versioning

/// 422 — A `POST /types` registration was rejected because the submitted
/// schema version doesn't match the structural diff class. The server
/// computes the diff between the prior and submitted schema and rejects
/// mismatched bumps:
/// - additive change → minor bump permitted
/// - field removed or required-tightened → major bump required
/// - description-only edit → patch bump permitted
///
/// The server emits this as `code: "version_bump_mismatch"`. Permanent —
/// the SyncEngine drops queued type-registration mutations carrying this
/// error rather than replaying them.
public final class SchemaVersionMismatchError: MarfaError, @unchecked Sendable {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(
            code: "version_bump_mismatch",
            message: message,
            status: 422,
            details: details
        )
    }
}

// MARK: - Local Mode

/// 501 — Operation requires a live server connection and is not available on a
/// pure-local ``MarfaClient`` created with ``MarfaClient/local(path:)``.
/// Blob uploads and downloads throw this when called on a local-only client.
public final class LocalModeUnsupportedError: MarfaError, @unchecked Sendable {
    public let operation: String

    public init(operation: String) {
        self.operation = operation
        super.init(
            code: "local_mode_unsupported",
            message:
                "\(operation) requires a live server connection. Use MarfaClient.synced(...) or MarfaClient(url:apiKey:) instead.",
            status: 501
        )
    }
}

// MARK: - Network Error

/// Transport-level failure (no connectivity, timeout, DNS, etc.).
public final class NetworkError: MarfaError, @unchecked Sendable {
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
public final class ResponseDecodingError: MarfaError, @unchecked Sendable {
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

struct APIErrorResponse: Codable, Sendable {
    let error: ErrorInfo
}

struct ErrorInfo: Codable, Sendable {
    let code: String
    let status: Int?
    let message: String?
    let details: [String: JSONValue]?
}
