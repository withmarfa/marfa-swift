extension Items {
    /// Each item the copy holds of `ids`, once each, in the order first named, read from one snapshot.
    ///
    /// Each item is what ``get(_:)-(String)`` answers for it alone. An ID the copy doesn't hold is left out, and so
    /// is an item in the bin unless `includingBin`. Unlike ``get(_:)-(String)``, which throws `hydrationIncomplete`
    /// for an item that hasn't arrived, this answers the items that have arrived while a hydration fills the copy and
    /// says `.partial`.
    public func get(_ ids: [String], includingBin: Bool = false) async throws -> Rows<Item> {
        try await holder.run { core in try core.getItems(ids: ids, includeBin: includingBin).answer }
    }

    /// What ``links(in:)-(String)`` answers for each item of `ids`, by ID, read against one catalog.
    ///
    /// An item the copy doesn't hold, holds in the bin, or whose stored properties it can't read is left out, so one
    /// such item never fails the read of the rest.
    public func links(in ids: [String]) async throws -> [String: BodyLinks] {
        try await holder.run { core in try core.bodyLinksOf(ids: ids).mapValues(BodyLinks.init) }
    }
}

extension Edges {
    /// The edge the copy holds by `id`, at the ends and version it holds now, or `nil`.
    ///
    /// Throws `hydrationIncomplete` until the copy is whole, as every read of edges does.
    public func get(_ id: String) async throws -> Edge? {
        try await holder.run { core in try core.edge(id: id).map(Edge.init) }
    }

    /// Each edge the copy holds of `ids`, once each, in the order first named; an ID it doesn't hold is left out.
    ///
    /// Throws `hydrationIncomplete` until the copy is whole, as every read of edges does.
    public func get(_ ids: [String]) async throws -> [Edge] {
        try await holder.run { core in try core.getEdges(ids: ids).map(Edge.init) }
    }
}

extension WorkingCopy {
    /// The items and edges that changed in the copy since `cursor`, and the cursor to pass next.
    ///
    /// An app that keeps what it shows in memory reads it all once, then asks this after each change it hears on
    /// ``changes()`` and rereads only the rows it names. The answer is ``CopyChanges/everything(next:)`` with no
    /// cursor, with one from another store, from beyond what the copy recorded, from before a change to the types or
    /// from before a removed edge the copy no longer records, and where more than `most` items or more than `most`
    /// edges changed: then read the whole copy again.
    ///
    /// An item is named where its row, its tags, an edge at either end of it, its pin or a write queued for it
    /// changed, so a name may change nothing on screen. One limit: an item whose body links read differently only
    /// because another item changed, such as a link that starts to resolve when its target arrives, is not named.
    /// An app that shows links reads ``Items/links(in:)-([String])`` again for the rows it shows whenever an answer
    /// names an item added, changed or removed.
    ///
    /// Throws `hydrationIncomplete` while a hydration is part way or the copy is stale, as every read of edges does,
    /// and `invalid` for text that isn't a cursor. Keep the cursor you passed until you have read what the
    /// answer names: a read refused `hydrationIncomplete` meanwhile is made again from that cursor once the copy is
    /// whole, which ``changes()`` tells as `.refreshed(.hydrated)`.
    public func changes(since cursor: ChangeCursor?, most: Int = 1_000) async throws -> CopyChanges {
        let changes = try await holder.run { core in
            try core.changesSince(cursor: cursor?.rawValue, most: UInt32(clamping: most))
        }
        let next = ChangeCursor(rawValue: changes.cursor)
        if changes.everything { return .everything(next: next) }
        return .named(
            ChangedRows(
                items: changes.items, removedItems: changes.removedItems, edges: changes.edges,
                removedEdges: changes.removedEdges),
            next: next)
    }
}

/// Where ``WorkingCopy/changes(since:most:)`` starts from: the point the answer that gave it was read at.
///
/// It has meaning only to the store that answered it. Keep it across launches as its `rawValue`; a cursor from
/// another store answers ``CopyChanges/everything(next:)``.
public struct ChangeCursor: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// What changed in a copy since a ``ChangeCursor``.
///
/// Switch over it: ``everything(next:)`` asks for the whole copy to be read again, and can't be read as an empty
/// set of changes.
public enum CopyChanges: Sendable, Hashable {
    /// The changes can't be named one by one: read the whole copy again, then pass `next`.
    case everything(next: ChangeCursor)
    /// Each row that changed: read these again, drop the removed ones, then pass `next`.
    case named(ChangedRows, next: ChangeCursor)

    /// Where the next call starts from, once what this answer names has been read.
    public var next: ChangeCursor {
        switch self {
        case .everything(let next), .named(_, let next): next
        }
    }
}

/// The rows ``CopyChanges/named(_:next:)`` names, each by ID.
public struct ChangedRows: Sendable, Hashable {
    /// Each changed item the copy holds, in the bin or out.
    ///
    /// Read them with ``Items/get(_:includingBin:)``; one the read leaves out has gone to the bin, unless the answer is
    /// `.partial`, when a hydration that started since may not have brought it back yet.
    public var items: [String]
    /// Each changed item the copy no longer holds.
    public var removedItems: [String]
    /// Each changed edge the copy holds.
    ///
    /// Read them with ``Edges/get(_:)-([String])``.
    public var edges: [String]
    /// Each changed edge the copy no longer holds.
    public var removedEdges: [String]

    public init(items: [String] = [], removedItems: [String] = [], edges: [String] = [], removedEdges: [String] = []) {
        self.items = items
        self.removedItems = removedItems
        self.edges = edges
        self.removedEdges = removedEdges
    }

    /// Nothing changed since the cursor.
    public var isEmpty: Bool { items.isEmpty && removedItems.isEmpty && edges.isEmpty && removedEdges.isEmpty }
}
