import Foundation

/// Threads API namespace — thin convenience over `/threads` records and
/// `in-thread` edges.
///
/// ## Data model
///
/// A thread is a standalone record (`GET/POST /threads`) that acts as the
/// target of `in-thread` edges. Each member item (note, highlight, media,
/// whatever) gets an `in-thread` edge with `source = memberId,
/// target = threadId`. Member ordering lives on the edge's
/// `properties.position`.
///
/// ## Why a wrapper
///
/// Adding a member is one SDK call (the edge). Listing members is one call
/// to `/threads/:id` (which the server returns as `{ thread, items }`).
/// Removing a member is a lookup plus a delete. The wrapper keeps that
/// bookkeeping in one place without hiding the underlying model — every
/// method maps one-to-one onto a short run of edge/thread calls, and
/// consumers can drop down to `client.edges` whenever they need something
/// bespoke.
///
/// ## Where this sits vs. `client.edges`
///
/// `client.edges` is the generic edge surface and works against any item.
/// `client.threads` wraps it for the thread case specifically — today's
/// thread records aren't items, so the item-centric edge-listing paths
/// (`GET /items/:id/backrefs`) don't accept a thread id as input. The
/// `/threads/:id` endpoint is the right way to enumerate members while
/// that remains true.
public struct ThreadsNamespace: Sendable {

    let transport: any Transport
    let items: ItemsNamespace
    let edges: EdgesNamespace

    /// The edge type that links a member item to its thread.
    public static let memberEdgeType = "in-thread"

    /// The `in-thread` edge property that carries a member's position.
    public static let positionProperty = "position"

    // MARK: - Thread records

    /// Creates a new thread record.
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

    /// Fetches a single thread record by ID.
    public func get(id: String) async throws -> MymeThread {
        let response: ThreadWithItemsResponse = try await transport.request(
            method: .get, path: "/threads/\(id)", body: nil, query: nil
        )
        return response.thread
    }

    // MARK: - Membership (via `in-thread` edges)

    /// Adds an item to a thread by creating an `in-thread` edge from the
    /// item to the thread. Returns the created edge.
    ///
    /// Pass `position` to place the member at an explicit ordinal; otherwise
    /// the position is left unset and the server orders by edge `created_at`.
    @discardableResult
    public func addMember(
        threadId: String,
        itemId: String,
        position: Double? = nil
    ) async throws -> Edge {
        var properties: [String: JSONValue]?
        if let position {
            properties = [Self.positionProperty: .double(position)]
        }
        return try await edges.create(
            source: itemId,
            target: threadId,
            edgeType: Self.memberEdgeType,
            properties: properties
        )
    }

    /// Removes an item from a thread.
    ///
    /// Deletes the first `in-thread` edge found between `itemId` and `threadId`.
    /// If no such edge exists, this is a no-op (returns `false`).
    /// Returns `true` when an edge was deleted.
    @discardableResult
    public func removeMember(threadId: String, itemId: String) async throws -> Bool {
        let page = try await items.edges(
            id: itemId,
            edgeType: Self.memberEdgeType,
            cursor: nil,
            limit: 200
        )
        guard let match = page.data.first(where: { $0.targetId == threadId }) else {
            return false
        }
        try await edges.delete(id: match.id)
        return true
    }

    /// Fetches a thread along with its current member items, via `GET /threads/:id`.
    ///
    /// The server returns member items directly, ordered by the underlying
    /// `in-thread` edges' `position` property. Use this as the primary "read
    /// a thread and what's in it" call.
    public func getWithMembers(id: String) async throws -> ThreadWithMembers {
        let response: ThreadWithItemsResponse = try await transport.request(
            method: .get, path: "/threads/\(id)", body: nil, query: nil
        )
        return ThreadWithMembers(thread: response.thread, items: response.items)
    }

    /// Convenience — just the member items for a thread, ordered by the server.
    public func memberItems(id: String) async throws -> [Item] {
        try await getWithMembers(id: id).items
    }

    /// Sets a member's `position` property on its `in-thread` edge.
    ///
    /// Building block for reorder flows — compute the new positions client-side,
    /// then issue one call per moved member.
    @discardableResult
    public func setPosition(edgeId: String, position: Double) async throws -> Edge {
        try await edges.update(
            id: edgeId,
            properties: [Self.positionProperty: .double(position)]
        )
    }
}

/// A thread plus its current member items — returned from `GET /threads/:id`.
public struct ThreadWithMembers: Sendable, Hashable {
    public let thread: MymeThread
    public let items: [Item]

    public init(thread: MymeThread, items: [Item]) {
        self.thread = thread
        self.items = items
    }
}

/// Wire shape of `GET /threads/:id` — internal; the public API exposes
/// `MymeThread` alone or `ThreadWithMembers` depending on the call.
struct ThreadWithItemsResponse: Codable, Sendable {
    let thread: MymeThread
    let items: [Item]
}
