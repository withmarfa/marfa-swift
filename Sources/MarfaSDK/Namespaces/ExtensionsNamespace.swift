import Foundation

/// Extensions API namespace. Manages namespaced metadata extensions.
///
/// An extension is a per-namespace `[String: JSONValue]` dictionary attached
/// to an item (e.g. `"search-index": { "status": "indexed" }`). The namespace
/// is opaque to the server and is scoped separately from item properties and
/// metadata tags.
///
/// In pure-local and synced modes the namespace routes through ``LocalStore``
/// first, enqueues the mutation for replay (in synced mode), and returns the
/// local result immediately.
public struct ExtensionsNamespace: Sendable {

    let transport: any Transport
    let localStore: LocalStore?
    let mutationQueue: MutationQueue?

    /// Gets all extension namespaces for an item.
    public func getAll(itemId: String) async throws -> [String: [String: JSONValue]] {
        if let store = localStore {
            return try await store.fetchExtensions(itemId: itemId)
        }
        let response: ExtensionsResponse = try await transport.request(
            method: .get, path: "/items/\(itemId)/extensions", body: nil, query: nil
        )
        return response.extensions
    }

    /// Gets a specific extension namespace for an item.
    public func get(itemId: String, namespace: String) async throws -> [String: JSONValue]? {
        if let store = localStore {
            return try await store.fetchExtension(itemId: itemId, namespace: namespace)
        }
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
        if let store = localStore {
            let result = try await store.setExtension(itemId: itemId, namespace: namespace, data: data)
            try await mutationQueue?.enqueueSetExtension(itemId: itemId, namespace: namespace, data: data)
            return result
        }
        let encoded = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? namespace
        let response: ExtensionsResponse = try await transport.request(
            method: .put, path: "/items/\(itemId)/extensions/\(encoded)",
            body: data, query: nil
        )
        return response.extensions
    }

    /// Deletes an extension namespace.
    public func delete(itemId: String, namespace: String) async throws {
        if let store = localStore {
            try await store.deleteExtension(itemId: itemId, namespace: namespace)
            try await mutationQueue?.enqueueDeleteExtension(itemId: itemId, namespace: namespace)
            return
        }
        let encoded = namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? namespace
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/items/\(itemId)/extensions/\(encoded)", body: nil, query: nil
        )
    }
}
