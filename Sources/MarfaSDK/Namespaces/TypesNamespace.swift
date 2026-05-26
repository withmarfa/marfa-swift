import Foundation

/// Types API namespace. Manages type schema registration and lookup.
///
/// A client created via ``MarfaClient/local(path:)`` has no live server;
/// every method here throws ``LocalModeUnsupportedError``.
public struct TypesNamespace: Sendable {

    let transport: any Transport

    /// `true` when this namespace is attached to a pure-local client. When
    /// set, every method throws before touching the transport.
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Lists all registered types.
    public func list() async throws -> [TypeSchema] {
        try ensureRemote("types.list")
        return try await transport.request(
            method: .get, path: "/types", body: nil, query: nil
        )
    }

    /// Gets a single type schema by ID.
    public func get(id: String) async throws -> TypeSchema {
        try ensureRemote("types.get")
        return try await transport.request(
            method: .get, path: "/types/\(id)", body: nil, query: nil
        )
    }

    /// Registers a custom type schema (admin only).
    public func register(_ schema: TypeSchema) async throws -> TypeSchema {
        try ensureRemote("types.register")
        let response: TypeResponse = try await transport.request(
            method: .post, path: "/types", body: schema, query: nil
        )
        return response.type
    }

    /// Updates a custom type schema (admin only).
    public func update(id: String, schema: TypeSchema) async throws -> TypeSchema {
        try ensureRemote("types.update")
        let response: TypeResponse = try await transport.request(
            method: .put, path: "/types/\(id)", body: schema, query: nil
        )
        return response.type
    }

    /// Deletes a custom type (admin only).
    public func delete(id: String, force: Bool = false) async throws {
        try ensureRemote("types.delete")
        var query: [(String, String)] = []
        if force { query.append(("force", "true")) }
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/types/\(id)", body: nil,
            query: query.isEmpty ? nil : query
        )
    }
}
