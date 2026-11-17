import Foundation
internal import MarfaCore

/// The links or table rows to count for each item.
public enum Counted: Sendable, Hashable {
    /// Active items at the other end of outgoing edges, as selected by `backref[<edge type>]`.
    /// For example, `parent-of` counts children.
    case backref(edgeType: String)
    /// Active items at the other end of incoming edges, as selected by `edge[<edge type>]`.
    /// For example, `in-collection` counts a collection's members.
    case edge(edgeType: String)
    /// The rows each item holds in the table.
    case rows(table: String)

    var core: MarfaCore.Counted {
        switch self {
        case .backref(let edgeType): .backref(edgeType: edgeType)
        case .edge(let edgeType): .edge(edgeType: edgeType)
        case .rows(let table): .table(table: table)
        }
    }
}

/// How many counted items are in each ``StatusGroup``.
public struct StatusGroupCounts: Sendable, Hashable {
    public var notStarted: Int
    public var inProgress: Int
    public var completed: Int
    public var canceled: Int

    public init(notStarted: Int = 0, inProgress: Int = 0, completed: Int = 0, canceled: Int = 0) {
        self.notStarted = notStarted
        self.inProgress = inProgress
        self.completed = completed
        self.canceled = canceled
    }

    /// The count for one group.
    public subscript(group: StatusGroup) -> Int {
        switch group {
        case .notStarted: notStarted
        case .inProgress: inProgress
        case .completed: completed
        case .canceled: canceled
        }
    }
}

/// A count for one item and the source of that count.
public struct ItemCount: Sendable, Hashable, Identifiable {
    /// The item counted for.
    public var id: String
    /// The number of matching items or rows.
    ///
    /// Incoming edges can contribute to the total even when the key cannot read their target.
    public var total: Int
    /// The counted items in each status group, or `nil` for table rows.
    ///
    /// An item with an absent or undeclared status contributes only to `total`.
    public var statusGroups: StatusGroupCounts?
    /// `true` when the copy supplied this count from local data, including queued changes.
    public var held: Bool

    public init(id: String, total: Int, statusGroups: StatusGroupCounts? = nil, held: Bool) {
        self.id = id
        self.total = total
        self.statusGroups = statusGroups
        self.held = held
    }

    init(_ core: MarfaCore.ItemCount) {
        self.init(
            id: core.id, total: Int(core.total),
            statusGroups: core.statusGroups.map {
                StatusGroupCounts(
                    notStarted: Int($0.notStarted), inProgress: Int($0.inProgress), completed: Int($0.completed),
                    canceled: Int($0.canceled))
            }, held: core.held)
    }
}

/// Neither the copy nor the server could answer a count.
///
/// Show "no count", never zero.
public enum CountError: Error, Sendable, Hashable, LocalizedError {
    /// The copy could not be sure, and the server could not be asked or did not answer. `cause` is why the server was
    /// out of reach; asking again once it can be reached may succeed.
    case unavailable(cause: MarfaError)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let cause): "No count: \(cause.localizedDescription)"
        }
    }
}

extension WorkingCopy {
    /// The most ids one request counts for.
    static let countBatch = 100

    /// How many items an edge type links to each of `ids`, by status group, or how many rows each holds in a table.
    ///
    /// Answers every id once, in the order they first appear, and counts only active items: what a list of the same
    /// items, naming no state, would show. The copy answers links where it can be sure of the number; where it
    /// cannot, it asks `server`, and ``ItemCount/held`` says which answered. Rows come from the copy for a table it
    /// holds whole, and from the server otherwise. More than 100 ids go in batches of 100.
    ///
    /// Throws ``CountError/unavailable(cause:)`` where the copy could not answer and `server` is `nil` or cannot be
    /// reached, and the app shows no count rather than 0. `server` is the one the copy was opened with: pass the
    /// current one after ``useKey(_:)``. Any other refusal is a ``MarfaError``.
    public func counts(of ids: [String], _ counted: Counted, server: Server? = nil) async throws -> [ItemCount] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        var answered: [ItemCount] = []
        for start in stride(from: 0, to: unique.count, by: Self.countBatch) {
            let batch = Array(unique[start..<min(start + Self.countBatch, unique.count)])
            answered += try await counts(batch, counted, server: server)
        }
        return answered
    }

    private func counts(_ ids: [String], _ counted: Counted, server: Server?) async throws -> [ItemCount] {
        let asked = counted.core
        do {
            return try await holder.runBlocking { core in
                try core.counts(ids: ids, counted: asked).map(ItemCount.init)
            }
        } catch MarfaError.invalid {
            // The copy refuses rather than undercount.
            guard let server else {
                throw CountError.unavailable(
                    cause: .noServer(message: "the copy cannot be sure of this count and was given no server to ask"))
            }
            do {
                return try await server.itemCounts(of: ids, counted)
            } catch {
                throw error.isTransient ? CountError.unavailable(cause: error) : error
            }
        } catch let error as MarfaError where error.isTransient || error.isNoServer {
            throw CountError.unavailable(cause: error)
        }
    }
}

extension MarfaError {
    fileprivate var isNoServer: Bool {
        if case .noServer = self { return true }
        return false
    }
}

extension Server {
    /// How many items an edge type links to each of `ids`, by status group, or how many rows each holds in a table,
    /// as `POST /items/counts` counts them.
    ///
    /// For up to 100 ids; the server answers each once, in order. Every ``ItemCount/held`` is `false`. A working copy
    /// asks for the count first, with ``WorkingCopy/counts(of:_:server:)``, and calls this only for what it cannot
    /// answer.
    public func itemCounts(
        of ids: [String], _ counted: Counted, timeout: Duration = Server.defaultTimeout
    ) async throws(MarfaError) -> [ItemCount] {
        var fields: [String: Any] = ["ids": ids]
        switch counted {
        case .backref(let edgeType): fields["backref"] = edgeType
        case .edge(let edgeType): fields["edge"] = edgeType
        case .rows(let table): fields["table"] = table
        }
        guard let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            throw .invalid(message: "the ids could not be written as json")
        }
        let answer: CountsWire = try decode(try await send("POST", "/items/counts", body: body, timeout: timeout))
        return answer.counts.map { wire in
            ItemCount(
                id: wire.id, total: wire.total,
                statusGroups: wire.statusGroups.map {
                    StatusGroupCounts(
                        notStarted: $0.notStarted, inProgress: $0.inProgress, completed: $0.completed,
                        canceled: $0.canceled)
                }, held: false)
        }
    }
}

private struct CountsWire: Decodable {
    struct Groups: Decodable {
        let notStarted: Int
        let inProgress: Int
        let completed: Int
        let canceled: Int
        enum CodingKeys: String, CodingKey {
            case notStarted = "not_started"
            case inProgress = "in_progress"
            case completed, canceled
        }
    }
    struct One: Decodable {
        let id: String
        let total: Int
        let statusGroups: Groups?
        enum CodingKeys: String, CodingKey {
            case id, total
            case statusGroups = "status_groups"
        }
    }
    let counts: [One]
}
