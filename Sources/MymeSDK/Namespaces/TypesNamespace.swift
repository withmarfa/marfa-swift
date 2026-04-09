import Foundation

/// Types API namespace. Manages type schema registration and lookup.
public struct TypesNamespace: Sendable {

    let transport: any Transport

    /// Lists all registered types.
    public func list() async throws -> [TypeSchema] {
        try await transport.request(
            method: .get, path: "/types", body: nil, query: nil
        )
    }

    /// Gets a single type schema by ID.
    public func get(id: String) async throws -> TypeSchema {
        try await transport.request(
            method: .get, path: "/types/\(id)", body: nil, query: nil
        )
    }

    /// Registers a custom type schema (admin only).
    public func register(_ schema: TypeSchema) async throws -> TypeSchema {
        let response: TypeResponse = try await transport.request(
            method: .post, path: "/types", body: schema, query: nil
        )
        return response.type
    }

    /// Updates a custom type schema (admin only).
    public func update(id: String, schema: TypeSchema) async throws -> TypeSchema {
        let response: TypeResponse = try await transport.request(
            method: .put, path: "/types/\(id)", body: schema, query: nil
        )
        return response.type
    }

    /// Deletes a custom type (admin only).
    public func delete(id: String, force: Bool = false) async throws {
        var query: [(String, String)] = []
        if force { query.append(("force", "true")) }
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/types/\(id)", body: nil,
            query: query.isEmpty ? nil : query
        )
    }
}
