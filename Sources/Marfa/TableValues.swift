internal import MarfaCore

/// Where a held table stands.
public enum TableState: Sendable, Hashable {
    /// Held, with no row read yet.
    case owed
    case filling
    /// Held whole, so reads and writes are answered from the copy.
    case whole
    /// Past the cap on rows a copy holds, so its reads go to the server.
    case online

    init(_ core: MarfaCore.TableState) {
        switch core {
        case .owed: self = .owed
        case .filling: self = .filling
        case .whole: self = .whole
        case .online: self = .online
        }
    }
}

/// What one pass over the tables not yet whole did.
public struct TableFill: Sendable, Hashable {
    /// Tables the pass left whole.
    public var whole: UInt64
    /// Tables past the cap, whose reads go to the server.
    public var online: UInt64
    /// Tables left still to fill, the failed ones among them.
    public var unfilled: UInt64
    public var pages: UInt64
    public var rows: UInt64
    /// Tables whose read failed, each left to the next pass.
    public var failed: UInt64
    /// Why the last of them failed.
    public var failure: String?

    public init(
        whole: UInt64 = 0, online: UInt64 = 0, unfilled: UInt64 = 0, pages: UInt64 = 0, rows: UInt64 = 0,
        failed: UInt64 = 0, failure: String? = nil
    ) {
        self.whole = whole
        self.online = online
        self.unfilled = unfilled
        self.pages = pages
        self.rows = rows
        self.failed = failed
        self.failure = failure
    }

    /// Whether the pass read rows or settled a table, so a view of the tables should read them again.
    var changedTables: Bool { rows > 0 || whole > 0 || online > 0 }

    init(_ core: MarfaCore.TableFill) {
        self.init(
            whole: core.whole, online: core.online, unfilled: core.unfilled, pages: core.pages, rows: core.rows,
            failed: core.failed, failure: core.failure)
    }
}

/// What ``Tables/hold(_:ofType:)`` did.
public struct TableHold: Sendable, Hashable {
    public var type: String
    public var table: String
    /// Whether the copy already held this choice.
    public var wasHeld: Bool
    /// What the fill that followed did; `nil` where the table was left owed instead.
    public var fill: TableFill?

    public init(type: String, table: String, wasHeld: Bool, fill: TableFill? = nil) {
        self.type = type
        self.table = table
        self.wasHeld = wasHeld
        self.fill = fill
    }

    init(_ core: MarfaCore.TableHold) {
        self.init(type: core.type, table: core.table, wasHeld: core.wasHeld, fill: core.fill.map(TableFill.init))
    }
}

/// A type and the table of it that the copy holds.
public struct TableChoice: Sendable, Hashable {
    /// The type, or the pattern of types, the choice was made by.
    public var type: String
    public var table: String

    public init(type: String, table: String) {
        self.type = type
        self.table = table
    }

    init(_ core: MarfaCore.TableChoice) {
        self.init(type: core.type, table: core.table)
    }
}

/// One table of one item that the copy holds.
public struct HeldTable: Sendable, Hashable {
    public var itemId: String
    public var table: String
    public var state: TableState
    /// How many rows the copy holds of it.
    public var rows: UInt64

    public init(itemId: String, table: String, state: TableState, rows: UInt64) {
        self.itemId = itemId
        self.table = table
        self.state = state
        self.rows = rows
    }

    init(_ core: MarfaCore.HeldTable) {
        self.init(itemId: core.itemId, table: core.table, state: TableState(core.state), rows: core.rows)
    }
}

/// The tables the copy holds, and the choices that name them.
public struct HeldTables: Sendable, Hashable {
    public var choices: [TableChoice]
    public var tables: [HeldTable]

    public init(choices: [TableChoice] = [], tables: [HeldTable] = []) {
        self.choices = choices
        self.tables = tables
    }

    init(_ core: MarfaCore.HeldTables) {
        self.init(choices: core.choices.map(TableChoice.init), tables: core.tables.map(HeldTable.init))
    }
}

/// What a read of a table's rows sorts by.
public enum TableSort: Sendable, Hashable {
    case id
    case updatedAt
    /// A column of the table, by its name.
    case column(String)

    var text: String {
        switch self {
        case .id: "id"
        case .updatedAt: "updated_at"
        case .column(let name): "values.\(name)"
        }
    }
}

/// A read of a table's rows: which, in what order and how many.
public struct RowsQuery: Sendable, Hashable {
    /// How many rows at most, 1 through 1000; the server's own default where `nil`.
    public var limit: Int?
    /// The `nextCursor` of the page before; `nil` for the first page.
    public var cursor: String?
    /// An expression in the item filter grammar, where `values.<column>` names a column and `id` and `updated_at`
    /// are the row's own.
    public var filter: String?
    /// The table's own order where `nil`: its declared `order` column, or `id`.
    public var sort: TableSort?
    public var direction: SortDirection?

    public init(
        limit: Int? = nil, cursor: String? = nil, filter: String? = nil, sort: TableSort? = nil,
        direction: SortDirection? = nil
    ) {
        self.limit = limit
        self.cursor = cursor
        self.filter = filter
        self.sort = sort
        self.direction = direction
    }

    var core: MarfaCore.RowsAsked {
        MarfaCore.RowsAsked(
            limit: limit.map { UInt32(clamping: $0) }, cursor: cursor, filter: filter, sort: sort?.text,
            direction: direction?.core)
    }
}

/// A row of an item's table.
///
/// A row is never an item: it has no version, tags or edges.
public struct TableRow: Sendable, Hashable {
    public var id: String
    /// The row's values by column; a column with no value is left out.
    public var values: JSONObject
    public var updatedAt: String
    /// The columns of type `item` that name an item the key cannot read, left out of `values`.
    public var withheld: [String]

    public init(id: String, values: JSONObject = [:], updatedAt: String, withheld: [String] = []) {
        self.id = id
        self.values = values
        self.updatedAt = updatedAt
        self.withheld = withheld
    }
}

/// A page of a table's rows.
public struct TableRowPage: Sendable, Hashable {
    public var rows: [TableRow]
    /// Pass it as ``RowsQuery/cursor`` for the next page; `nil` when there are no more.
    public var nextCursor: String?

    public init(rows: [TableRow] = [], nextCursor: String? = nil) {
        self.rows = rows
        self.nextCursor = nextCursor
    }
}

/// The totals of a table's columns that add up, over the rows a filter selects.
public struct TableTotals: Sendable, Hashable {
    /// How many rows the filter selects.
    public var rowCount: Int64
    /// For each column that adds up, an object with the way it adds up (`sum`, `count`, `average`, `min` or
    /// `max`) as its one key.
    public var totals: JSONObject

    public init(rowCount: Int64 = 0, totals: JSONObject = [:]) {
        self.rowCount = rowCount
        self.totals = totals
    }
}

/// What a read of a table answered, and whether the copy answered it.
///
/// A table the copy holds whole is answered from the copy, with `held` set. Otherwise the copy asked the server,
/// which needs it to be reachable, and `held` is not set.
public struct TableAnswer<Value: Sendable & Hashable>: Sendable, Hashable {
    public var value: Value
    public var held: Bool

    public init(_ value: Value, held: Bool) {
        self.value = value
        self.held = held
    }
}

/// One change to a row of a table.
public enum RowOperation: Sendable, Hashable {
    /// Writes the whole row, replacing it where it exists. The server makes an `id` left `nil`.
    case put(id: String? = nil, values: JSONObject)
    /// Sets only the columns `values` names; `null` clears a column.
    case patch(id: String, values: JSONObject)
    case delete(id: String)

    var core: MarfaCore.JsonObject {
        switch self {
        case .put(let id, let values):
            var object: JSONObject = ["op": "put"]
            if let id { object["id"] = .string(id) }
            object["values"] = .object(values)
            return object.core
        case .patch(let id, let values):
            return JSONObject([("op", "patch"), ("id", .string(id)), ("values", .object(values))]).core
        case .delete(let id):
            return JSONObject([("op", "delete"), ("id", .string(id))]).core
        }
    }
}

extension TableAnswer where Value == TableRowPage {
    init(page core: MarfaCore.JsonObject) throws {
        let object = JSONObject(core)
        let held = try object.held()
        let data = try object.array("data")
        let rows = try data.map { try TableRow($0) }
        let next: String?
        switch object["next_cursor"] {
        case .string(let cursor): next = cursor
        case .null, nil: next = nil
        default: throw MarfaError.decoding(message: "a page of rows answered a next_cursor that is not text")
        }
        self.init(TableRowPage(rows: rows, nextCursor: next), held: held)
    }
}

extension TableAnswer where Value == TableRow {
    init(row core: MarfaCore.JsonObject) throws {
        let object = JSONObject(core)
        self.init(try TableRow(.object(object)), held: try object.held())
    }
}

extension TableAnswer where Value == TableTotals {
    init(totals core: MarfaCore.JsonObject) throws {
        let object = JSONObject(core)
        guard case .integer(let count) = object["row_count"] else {
            throw MarfaError.decoding(message: "a table's totals answered a row_count that is not an integer")
        }
        guard case .object(let totals) = object["totals"] else {
            throw MarfaError.decoding(message: "a table's totals answered totals that are not an object")
        }
        self.init(TableTotals(rowCount: count, totals: totals), held: try object.held())
    }
}

extension TableRow {
    fileprivate init(_ value: JSONValue) throws {
        guard case .object(let object) = value, case .string(let id) = object["id"],
            case .object(let values) = object["values"], case .string(let updatedAt) = object["updated_at"]
        else {
            throw MarfaError.decoding(message: "a row of a table answered without an id, values and updated_at")
        }
        var withheld: [String] = []
        if let named = object["withheld"] {
            guard case .array(let columns) = named, let names = columns.map(\.string) as? [String] else {
                throw MarfaError.decoding(message: "a row of a table answered withheld columns that are not text")
            }
            withheld = names
        }
        self.init(id: id, values: values, updatedAt: updatedAt, withheld: withheld)
    }
}

extension JSONObject {
    fileprivate func held() throws -> Bool {
        guard case .bool(let held) = self["held"] else {
            throw MarfaError.decoding(message: "a table read answered without saying whether the copy held it")
        }
        return held
    }

    fileprivate func array(_ key: String) throws -> [JSONValue] {
        guard case .array(let values) = self[key] else {
            throw MarfaError.decoding(message: "a table read answered \(key) that is not a list")
        }
        return values
    }
}
