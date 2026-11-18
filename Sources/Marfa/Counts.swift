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
    /// The copy could not answer, and it has no server or could not reach it. `cause` is ``MarfaError/noServer(message:)``,
    /// ``MarfaError/noConnection(message:)`` or ``MarfaError/network(message:)``; asking again once the server can be
    /// reached may succeed.
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
    /// cannot, it asks the server it was opened with, under the key it holds now, and ``ItemCount/held`` says which
    /// answered. Rows come from the copy for a table it holds whole, and from the server otherwise. More than 100 ids
    /// go in batches of 100, and a canceled task asks for no further batch. Every count returned was answered by the
    /// open copy under the key it holds when it returns, with no key change begun since the call began. Where
    /// ``useKey(_:)`` began during the call, the counts are asked again once it ends, under the key it leaves.
    /// A call made while the key is changing throws `keyChanging`, and a call on a copy that is closing, or that
    /// closed because ``useKey(_:)`` could not open its store again, throws `closed`, whatever the ids.
    ///
    /// Throws ``CountError/unavailable(cause:)`` where the copy could not answer and has no server or cannot reach it,
    /// and the app shows no count rather than 0. Any other failure, such as a server's refusal or a failed renewal of
    /// the key, is the ``MarfaError`` itself.
    public func counts(of ids: [String], _ counted: Counted) async throws -> [ItemCount] {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let batches = stride(from: 0, to: unique.count, by: Self.countBatch).map {
            Array(unique[$0..<min($0 + Self.countBatch, unique.count)])
        }
        let asked = counted.core
        var epoch = try holder.steadyEpoch()
        do {
            asking: while true {
                var counts: [ItemCount] = []
                // One call per batch, so a canceled task stops before the next batch.
                for batch in batches {
                    let answer = try await holder.runBlocking { core in
                        do {
                            return try core.counts(ids: batch, counted: asked).map(ItemCount.init)
                        } catch MarfaCore.MarfaError.NotAnswerable {
                            return try core.servedCounts(ids: batch, counted: asked).map(ItemCount.init)
                        }
                    }
                    guard try holder.isSteady(since: epoch) else {
                        epoch = try await holder.steadyEpochAfterKeyChange()
                        continue asking
                    }
                    counts += answer
                }
                return counts
            }
        } catch let error as MarfaError where error.isUnreachable {
            throw CountError.unavailable(cause: error)
        }
    }
}

extension MarfaError {
    fileprivate var isUnreachable: Bool {
        switch self {
        case .noServer, .noConnection, .network: true
        default: false
        }
    }
}

extension Server {
    /// How many items an edge type links to each of `ids`, by status group, or how many rows each holds in a table,
    /// as `POST /items/counts` counts them.
    ///
    /// For up to 100 ids; the server answers each once, in the order they first appear. Every ``ItemCount/held`` is
    /// `false`. A working copy's ``WorkingCopy/counts(of:_:)`` asks its own server for what it cannot answer, so call
    /// this only without a copy. Throws ``MarfaError/decoding(message:)`` for an answer that is not the asked ids
    /// once each in that order, a negative count, a link count without its four status groups or with groups that
    /// are negative or add up to more than its total, or a count of rows with `status_groups`, `null` included.
    public func itemCounts(
        of ids: [String], _ counted: Counted, timeout: Duration = Server.defaultTimeout
    ) async throws(MarfaError) -> [ItemCount] {
        var fields: [String: Any] = ["ids": ids]
        let linked: Bool
        switch counted {
        case .backref(let edgeType): (fields["backref"], linked) = (edgeType, true)
        case .edge(let edgeType): (fields["edge"], linked) = (edgeType, true)
        case .rows(let table): (fields["table"], linked) = (table, false)
        }
        guard let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            throw .invalid(message: "the ids could not be written as json")
        }
        let answer: CountsWire = try decode(try await send("POST", "/items/counts", body: body, timeout: timeout))
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        guard answer.counts.map(\.id) == unique else {
            throw .decoding(message: "\(origin) answered counts that are not the asked ids, once each and in order")
        }
        return try answer.counts.map { wire throws(MarfaError) in
            guard wire.total >= 0 else { throw .decoding(message: "\(origin) answered a negative count") }
            switch (linked, wire.statusGroups) {
            case (true, nil):
                throw .decoding(message: "\(origin) answered a count of links without its status groups")
            case (false, .some):
                throw .decoding(message: "\(origin) answered a count of rows with status groups")
            case (false, nil):
                return ItemCount(id: wire.id, total: wire.total, held: false)
            case (true, .some(let groups)):
                guard groups.fit(wire.total) else {
                    throw .decoding(message: "\(origin) answered status groups that do not fit their count")
                }
                return ItemCount(
                    id: wire.id, total: wire.total,
                    statusGroups: StatusGroupCounts(
                        notStarted: groups.notStarted, inProgress: groups.inProgress, completed: groups.completed,
                        canceled: groups.canceled), held: false)
            }
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

        func fit(_ total: Int) -> Bool {
            var sum = 0
            for group in [notStarted, inProgress, completed, canceled] {
                guard group >= 0 else { return false }
                let (added, overflow) = sum.addingReportingOverflow(group)
                guard !overflow, added <= total else { return false }
                sum = added
            }
            return true
        }
    }
    struct One: Decodable {
        let id: String
        let total: Int
        /// `status_groups` present as `null` is refused, not read as absent.
        let statusGroups: Groups?
        enum CodingKeys: String, CodingKey {
            case id, total
            case statusGroups = "status_groups"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            total = try container.decode(Int.self, forKey: .total)
            statusGroups =
                container.contains(.statusGroups) ? try container.decode(Groups.self, forKey: .statusGroups) : nil
        }
    }
    let counts: [One]
}
