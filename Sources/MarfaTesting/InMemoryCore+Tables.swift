#if DEBUG
import MarfaCore

/// The fake holds no table: it has no server to fill one from, so it answers what a copy that holds none answers,
/// and every call that needs a table's rows or its type's declaration throws `FakeCopyError.unsupported`.
extension InMemoryCore {
    private func unsupported<T>(_ call: String) throws -> T {
        throw FakeCopyError.unsupported(call: call)
    }

    func holdTable(typeId: String, table: String, stop: Stop?) throws -> TableHold {
        try unsupported("tables.hold")
    }

    func letGoTable(typeId: String, table: String) throws -> Bool {
        false
    }

    func heldTables() throws -> HeldTables {
        HeldTables(choices: [], tables: [])
    }

    func fillTables(stop: Stop?) throws -> TableFill {
        try unsupported("tables.fill")
    }

    func tableRows(itemId: String, table: String, asked: RowsAsked?) throws -> JsonObject {
        try unsupported("tables.rows")
    }

    func tableRow(itemId: String, table: String, row: String) throws -> JsonObject {
        try unsupported("tables.row")
    }

    func counts(ids: [String], counted: Counted) throws -> [ItemCount] {
        try unsupported("counts")
    }

    func servedCounts(ids: [String], counted: Counted) throws -> [ItemCount] {
        try unsupported("servedCounts")
    }

    func tableTotals(itemId: String, table: String, filter: String?) throws -> JsonObject {
        try unsupported("tables.totals")
    }

    func writeRows(itemId: String, table: String, operations: [JsonObject]) throws -> QueuedWrite {
        try requireItem(itemId)
        return try unsupported("tables.write")
    }

    func undoRows(itemId: String, table: String, batch: String) throws -> QueuedWrite {
        try requireItem(itemId)
        return try unsupported("tables.undo")
    }

    /// An item the copy does not hold is refused as the core refuses it, before the table is looked at.
    private func requireItem(_ id: String) throws {
        guard state.withLock({ $0.items[id] != nil }) else { throw Refuse.item(id) }
    }
}
#endif
