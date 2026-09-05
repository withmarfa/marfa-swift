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
// `@unchecked` is load-bearing on an `open` class: an external subclass
// can add mutable state the compiler cannot see from here, so checked
// `Sendable` is unavailable even though every stored property below is
// immutable. Subclasses inherit the conformance and add only `let`s;
// a subclass introducing mutable state must revisit this.
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
    ///
    /// This is context-free by design: it sees a status, not what the request
    /// was trying to do. `409` is the case where that matters. On an update it
    /// is the ordinary version conflict and belongs to the conflict strategy,
    /// but on a *create* nothing can resolve it — a repeat of the caller's own
    /// id is acknowledged by the server rather than refused, so a 409 that
    /// does arrive names somebody else's row or a type that disagrees.
    /// ``SyncEngine`` therefore drops a create meeting a 409 without consulting
    /// this property. A caller reasoning about a queued create should do the
    /// same rather than reading `isPermanent` as the whole rule.
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
public final class NotFoundError: MarfaError {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "not_found", message: message, status: 404, details: details)
    }
}

/// 400 — request failed validation.
public final class ValidationError: MarfaError {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "validation_error", message: message, status: 400, details: details)
    }

    /// A 400 that named a code of its own.
    ///
    /// Most 400s are the generic validation failure and the default init
    /// covers them. Some carry the whole of their meaning in the code
    /// instead — `bulk_atomic_rollback` is one, and it says only that a page
    /// was rolled back, with the entry and the reason in `details`. Flattening
    /// those to `validation_error` at the parser loses the one field a caller
    /// can act on.
    public init(code: String, message: String, details: [String: JSONValue]? = nil) {
        super.init(code: code, message: message, status: 400, details: details)
    }
}

/// 401 — invalid or expired credentials.
public final class UnauthorizedError: MarfaError {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "unauthorized", message: message, status: 401, details: details)
    }
}

/// 403 — valid credentials but insufficient permissions.
public final class ForbiddenError: MarfaError {
    public init(message: String, details: [String: JSONValue]? = nil) {
        super.init(code: "forbidden", message: message, status: 403, details: details)
    }
}

/// 409 — version conflict with resolution data.
public final class ConflictError: MarfaError {
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

    /// Convenience initializer for 409 conflicts without version-conflict
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
public final class SchemaVersionMismatchError: MarfaError {
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
public final class LocalModeUnsupportedError: MarfaError {
    public let operation: String

    /// Overridden rather than widening the 501 band in ``MarfaError/isPermanent``.
    /// A *server* answering 501 is a different question — a route mid-rollout
    /// or a proxy — and `PendingMutationBlockReason` deliberately treats a 5xx
    /// as transient so a queued write survives it. Widening the band there
    /// would turn those into dropped writes, which is a much larger change
    /// than the caller-facing one this needs.
    public override var isPermanent: Bool { true }

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

/// 501 — A narrowing the caller asked for cannot be applied where the request
/// is being resolved, so the request is refused rather than answered wider
/// than it was asked.
///
/// Raised by a bulk action on a client that resolves its own match set — local
/// or synced — when the filter carries the server's `filter` expression. That
/// grammar reaches across edges and is evaluated by the server; the local
/// store does not implement it. Resolving without it would hand the action
/// every row the remaining fields allow, and two of the six actions are
/// `purge` and `transition`.
///
/// **A remote client never sees this.** It has no store, so its bulk action
/// goes to the server, which evaluates its own grammar. Narrow with the
/// structured fields — `type`, `state`, `source`, `tier`, `tags`,
/// `timestampAfter`, `timestampBefore` — or perform the action through a
/// remote client.
public final class LocalFilterUnsupportedError: MarfaError {
    /// Refusing a narrowing this path cannot apply is final by construction:
    /// the same call on the same client resolves the same way every time. See
    /// ``LocalModeUnsupportedError`` for why this is an override rather than a
    /// widening of the status band.
    public override var isPermanent: Bool { true }

    /// The call that was refused, e.g. `items.bulkAction`.
    public let operation: String
    /// The narrowing that could not be applied, e.g. `filter`.
    public let field: String

    public init(operation: String, field: String) {
        self.operation = operation
        self.field = field
        super.init(
            code: "local_filter_unsupported",
            message:
                "\(operation) cannot apply the `\(field)` narrowing on a client that resolves locally, and will not act on a wider set than was asked for. Narrow with the filter's structured fields instead, or perform the action through a client built with MarfaClient(url:apiKey:).",
            status: 501
        )
    }
}

/// 400 — A `purge` bulk action was submitted without its confirmation.
///
/// Mirrors the server's `bulk_confirmation_required`. The confirmation used to
/// be enforced only inside `BulkActionInput`'s encoder, which runs when a
/// mutation is queued — so a client resolving locally applied the purge first
/// and threw afterwards, and a client with no queue never encoded at all and
/// purged with no confirmation whatsoever.
public final class BulkConfirmationRequiredError: MarfaError {
    public init() {
        super.init(
            code: "bulk_confirmation_required",
            message: #"A purge bulk action requires options.confirm == "PURGE"."#,
            status: 400
        )
    }
}

/// 400 — A bulk action matched more rows than `maxItems` allows.
///
/// Mirrors the server's `bulk_cap_exceeded`, and the direction is the whole
/// point: the cap **refuses the action**, it does not trim the match set. A
/// client resolving locally used to pass the cap down as a fetch window, so a
/// purge capped at one row purged one arbitrary row of the many that matched,
/// reported `matched: 1`, and returned no error — a safety brake that quietly
/// became a partial write.
public final class BulkCapExceededError: MarfaError {
    /// How many rows the filter actually matched.
    public let matched: Int
    /// The cap the caller set.
    public let cap: Int

    public init(matched: Int, cap: Int) {
        self.matched = matched
        self.cap = cap
        super.init(
            code: "bulk_cap_exceeded",
            message: "The filter matched \(matched) items, above the maxItems cap of \(cap). Nothing was applied. Narrow the filter or raise the cap.",
            status: 400
        )
    }
}

// MARK: - Network Error

/// Transport-level failure (no connectivity, timeout, DNS, etc.).
public final class NetworkError: MarfaError {
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
public final class ResponseDecodingError: MarfaError {
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
