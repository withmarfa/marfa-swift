import Foundation

/// Strategy for resolving version conflicts during item updates.
public enum ConflictStrategy: Sendable {
    /// Auto-merge non-conflicting fields. Server wins on conflicts. Retries up to 3 times.
    case auto

    /// Throw `ConflictError` immediately, letting the caller handle resolution.
    case manual

    /// Call a custom resolver function. Retries up to 3 times with the resolver's output.
    case callback
}

/// Data provided to a conflict resolver.
public struct ConflictData: Sendable {
    /// The server's current state.
    public let current: ConflictSnapshot

    /// The last common ancestor state.
    public let ancestor: ConflictSnapshot

    /// Fields that differ between the client patch and server state.
    public let conflictingFields: [String]

    /// The properties the client attempted to write.
    public let clientPatch: [String: JSONValue]
}

/// A point-in-time snapshot of item version and properties.
public struct ConflictSnapshot: Codable, Sendable, Hashable {
    public let version: Int
    public let properties: [String: JSONValue]
}

/// Server conflict response (HTTP 409).
public struct ConflictResponse: Codable, Sendable {
    public let error: ConflictErrorInfo
    public let current: ConflictSnapshot
    public let ancestor: ConflictSnapshot?
    // swiftlint:disable:next identifier_name
    public let conflicting_fields: [String]

    public struct ConflictErrorInfo: Codable, Sendable {
        public let code: String
        public let status: Int?
    }
}

/// A function that resolves a version conflict by producing merged properties.
public typealias ConflictResolver = @Sendable (ConflictData) async throws -> [String: JSONValue]

/// Result of a request that may return a 409 conflict.
public enum ConflictResult<T: Sendable>: Sendable {
    case success(T)
    case conflict(ConflictResponse)
}
