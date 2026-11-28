internal import MarfaCore

/// The tables of the items a copy holds: which the copy holds, their rows, and the writes to them.
///
/// An item of a type that declares a table, or one that carries its own `columns`, has rows in that table. The
/// copy holds a table as its slice holds an item: the app names a type and a table, and the copy holds that table of
/// each item of the type it holds. A table is held whole or not at all, and a table the copy does not hold whole is
/// read from the server.
public struct Tables: Sendable {
    let holder: CoreHolder
    let feed: Feed

    /// Holds the table named `table` of every item the copy holds of `type`, and fills it, so its rows are read
    /// offline and a write to them shows at once.
    ///
    /// `type` is a type, or a pattern of types as ``WorkingCopy/hydrate(types:tier:edgeTypes:inPlaceOnly:)`` takes
    /// it. The copy keeps the choice and holds the table of an item that arrives later. The fill needs the server and
    /// runs where no other call holds the copy's stream and its hydration is complete. Otherwise `fill` is `nil` and
    /// the table stays owed for the next follow or catch-up, or ``fill()``. Throws `invalid` for a table that no
    /// type `type` names declares. Tells every held stream `.refreshed(.tables)` for a new choice or a fill that read
    /// rows, completed a table, or found one past the cap. A catch-up lists the tables it filled in
    /// ``CatchUpReport/changedTables``. When the follow fills a table, ``WorkingCopy/changes()`` reports
    /// `.refreshed(.tables)` with the item's ID.
    public func hold(_ table: String, ofType type: String) async throws -> TableHold {
        let hold = try await holder.runUntilCanceled { core, stop in
            TableHold(try core.holdTable(typeId: type, table: table, stop: stop))
        }
        if !hold.wasHeld || hold.fill?.changedTables == true {
            feed.announce(Change(origin: .refreshed(.tables), itemId: nil, edgeId: nil))
        }
        return hold
    }

    /// Lets go of a choice made with ``hold(_:ofType:)``, keeping a table that another choice holds, and drops the
    /// rows of each table no choice holds; `false` where the copy held no such choice.
    ///
    /// A write to one of those rows that is still queued stays queued.
    public func letGo(_ table: String, ofType type: String) async throws -> Bool {
        let released = try await holder.run { core in try core.letGoTable(typeId: type, table: table) }
        if released { feed.announce(Change(origin: .refreshed(.tables), itemId: nil, edgeId: nil)) }
        return released
    }

    /// The tables the copy holds, with the state of each, and the choices that name them.
    public func held() async throws -> HeldTables {
        try await holder.run { core in HeldTables(try core.heldTables()) }
    }

    /// Fills each table the copy holds that is not whole yet, from the server.
    ///
    /// Call this to fill tables without waiting for a catch-up or the follow. The next pass retries tables whose
    /// reads failed. ``TableFill/failed`` counts those failures. A pass that reads rows, completes a table (even an
    /// empty one), or finds a table past the cap sends `.refreshed(.tables)` to every held change stream.
    public func fill() async throws -> TableFill {
        let fill = try await holder.runUntilCanceled { core, stop in TableFill(try core.fillTables(stop: stop)) }
        if fill.changedTables {
            feed.announce(Change(origin: .refreshed(.tables), itemId: nil, edgeId: nil))
        }
        return fill
    }

    /// A page of the rows of `table` of `item`.
    ///
    /// From the copy where it holds the table whole, with every waiting write laid over the rows, and `held` set;
    /// from the server otherwise, which a copy offline or with no server cannot reach.
    public func rows(of item: String, in table: String, _ query: RowsQuery = RowsQuery()) async throws
        -> TableAnswer<TableRowPage>
    {
        let asked = query.core
        return try await holder.runBlocking { core in
            try TableAnswer(page: try core.tableRows(itemId: item, table: table, asked: asked))
        }
    }

    /// The row `id` of `table` of `item`, answered as ``rows(of:in:_:)`` answers a page.
    ///
    /// Throws `notFound` for a row the table does not hold.
    public func row(_ id: String, of item: String, in table: String) async throws -> TableAnswer<TableRow> {
        try await holder.runBlocking { core in
            try TableAnswer(row: try core.tableRow(itemId: item, table: table, row: id))
        }
    }

    /// The totals of the columns of `table` of `item` that add up, over the rows `filter` selects, or all of them
    /// where `nil`; answered as ``rows(of:in:_:)`` answers a page.
    public func totals(of item: String, in table: String, filter: String? = nil) async throws
        -> TableAnswer<TableTotals>
    {
        try await holder.runBlocking { core in
            try TableAnswer(totals: try core.tableTotals(itemId: item, table: table, filter: filter))
        }
    }

    /// Queues one batch of changes to the rows of `table` of `item`, and shows it over the rows the copy holds at
    /// once.
    ///
    /// The server takes all of a batch or none of it. A drain sends consecutive batches to one table in one request
    /// and gives each its own verdict: `accepted`, `conflicted` naming in ``Verdict/conflicted(siblingId:fields:conflicts:)``
    /// the cells it replaced that the copy had not shown, or `refused`. The accepted write's answer holds
    /// the `batch` to undo, which ``QueuedWrite/rowBatch`` reads.
    ///
    /// Throws `notFound` for an item the copy does not hold (`item_not_found`) and for a table the item does not have
    /// (`table_not_found`), and `validation` for an operation the server would refuse and the copy can tell; nothing
    /// is queued then.
    public func write(_ operations: [RowOperation], to table: String, of item: String) async throws -> QueuedWrite {
        let operations = operations.map(\.core)
        return try await queued(holder, feed) { core in
            try core.writeRows(itemId: item, table: table, operations: operations)
        }
    }

    /// Queues the undo of `batch`, a batch the server took for `table` of `item`.
    ///
    /// No row the copy holds changes until the server's event for the undo arrives.
    public func undo(batch: String, in table: String, of item: String) async throws -> QueuedWrite {
        try await queued(holder, feed) { core in
            try core.undoRows(itemId: item, table: table, batch: batch)
        }
    }
}

extension QueuedWrite {
    /// The batch the server made of a row write or an undo it accepted, which ``Tables/undo(batch:in:of:)`` undoes;
    /// `nil` for any other write, and for an undo the server made no batch of.
    public var rowBatch: String? {
        guard kind == .writeRows || kind == .undoRows, case .object(let answer)? = answer,
            case .string(let batch)? = answer["batch"]
        else { return nil }
        return batch
    }
}
