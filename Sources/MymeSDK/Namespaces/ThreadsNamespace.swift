import Foundation

/// Threads API namespace. Manages sequential grouping of items.
public struct ThreadsNamespace: Sendable {

    let transport: any Transport

    /// Creates a new thread.
    public func create() async throws -> MymeThread {
        let response: ThreadResponse = try await transport.request(
            method: .post, path: "/threads", body: nil, query: nil
        )
        return response.thread
    }

    /// Lists threads with pagination.
    public func list(limit: Int? = nil, cursor: String? = nil) async throws -> PaginatedResult<MymeThread> {
        var query: [(String, String)] = []
        if let limit { query.append(("limit", String(limit))) }
        if let cursor { query.append(("cursor", cursor)) }
        return try await transport.request(
            method: .get, path: "/threads", body: nil,
            query: query.isEmpty ? nil : query
        )
    }

    /// Gets a thread and its associated items.
    public func get(id: String) async throws -> ThreadWithItems {
        try await transport.request(
            method: .get, path: "/threads/\(id)", body: nil, query: nil
        )
    }

    /// Adds an item to a thread.
    public func addItem(threadId: String, itemId: String) async throws -> Item {
        let response: ItemResponse = try await transport.request(
            method: .post, path: "/threads/\(threadId)/items",
            body: ["item_id": JSONValue.string(itemId)], query: nil
        )
        return response.item
    }

    /// Removes an item from a thread.
    public func removeItem(threadId: String, itemId: String) async throws -> Item {
        let response: ItemResponse = try await transport.request(
            method: .delete, path: "/threads/\(threadId)/items/\(itemId)",
            body: nil, query: nil
        )
        return response.item
    }
}
