import Foundation

/// Extensions API namespace. Manages namespaced metadata extensions.
public struct ExtensionsNamespace: Sendable {

    let transport: any Transport

    /// Gets all extension namespaces for an item.
    public func getAll(itemId: String) async throws -> [String: [String: JSONValue]] {
        let response: ExtensionsResponse = try await transport.request(
            method: .get, path: "/items/\(itemId)/extensions", body: nil, query: nil
        )
        return response.extensions
    }

    /// Gets a specific extension namespace for an item.
    public func get(itemId: String, namespace: String) async throws -> [String: JSONValue]? {
        let encoded = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? namespace
        let response: NamespaceResponse = try await transport.request(
            method: .get, path: "/items/\(itemId)/extensions/\(encoded)", body: nil, query: nil
        )
        return response.data
    }

    /// Writes data to an extension namespace.
    public func set(
        itemId: String,
        namespace: String,
        data: [String: JSONValue]
    ) async throws -> [String: [String: JSONValue]] {
        let encoded = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? namespace
        let response: ExtensionsResponse = try await transport.request(
            method: .put, path: "/items/\(itemId)/extensions/\(encoded)",
            body: data, query: nil
        )
        return response.extensions
    }

    /// Deletes an extension namespace.
    public func delete(itemId: String, namespace: String) async throws {
        let encoded = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? namespace
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/items/\(itemId)/extensions/\(encoded)", body: nil, query: nil
        )
    }
}
