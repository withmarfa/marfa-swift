#if DEBUG
import Foundation
import MarfaCore
import SQLite3

/// Search over the fake's rows, answered by the engine the real core's index is: SQLite's FTS5 with the
/// `porter unicode61` tokenizer, the columns and the ranking (`bm25`, ties by item ID) and the excerpt
/// (`snippet`, 32 words) the core uses.
///
/// Matching, stemming, ranking and excerpts are therefore not reimplemented here. Each search builds a
/// throwaway in-memory index of the rows the copy holds outside the bin, which costs one pass over the
/// rows, and discards it. What this file does write is the part the core writes in Rust: which text of a
/// row goes into which column, how a query becomes an FTS5 expression, and how an excerpt becomes HTML.
extension InMemoryCore {
    func search(query: String, filters: SearchFilters, limit: UInt32) throws -> Found {
        if filters.filter != nil { throw FakeCopyError.unsupported(call: "search(filter:)") }
        let named = try Self.states(of: filters.states, allStates: filters.allStates)
        let occurredAfter = try filters.occurredAfter.map(Checks.occurred)
        let occurredBefore = try filters.occurredBefore.map(Checks.occurred)
        return try state.withLock { state in
            let types = state.resolvedItemTypes()
            let roots = try Self.roots(of: filters.types, in: types)
            let beneath = filters.beneath.map { state.reached(from: $0) }
            let allowed = state.items.values.filter { item in
                if let roots, !roots.contains(where: { Self.reaches(item.type, $0, in: types) }) { return false }
                if let named, !named.contains(item.state) { return false }
                if let tier = filters.tier, item.tier != tier { return false }
                if let occurredAfter, item.occurredAt <= occurredAfter { return false }
                if let occurredBefore, item.occurredAt >= occurredBefore { return false }
                if let beneath, !beneath.contains(item.id) { return false }
                return filters.tags.allSatisfy(item.tags.contains)
            }
            return try Self.found(query, among: Set(allowed.map(\.id)), limit: limit, in: state, types: types)
        }
    }

    func searchInView(query: String, id: String, limit: UInt32) throws -> Found {
        try state.withLock { state in
            let (_, matched) = try Self.scope(id, in: state, call: "search(inView:)")
            return try Self.found(
                query, among: Set(matched.map(\.id)), limit: limit, in: state, types: state.resolvedItemTypes())
        }
    }

    // MARK: Index

    private static let markOpen = "\u{E000}"
    private static let markClose = "\u{E001}"

    /// The rows of `allowed` that match, ranked among every row the index holds, as the core ranks them: the
    /// index is the whole copy outside the bin, and only then is it narrowed.
    private static func found(
        _ query: String, among allowed: Set<String>, limit: UInt32, in state: State, types: [String: ItemType]
    ) throws -> Found {
        guard let expression = expression(of: query) else { return Found(hits: [], completeness: .complete) }
        let database = try FullTextIndex()
        let held = state.items.values
            .filter { $0.state != .trashed }
            .sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
        try database.fill(held, allowed: allowed) { columns(of: $0, type: types[$0.type]) }
        let hits = try database.rank(expression, open: markOpen, close: markClose, limit: Int64(limit))
        return Found(
            hits: hits.compactMap { id, rank, excerpt in
                state.items[id].map { SearchHit(item: $0, score: -rank, snippet: html(excerpt)) }
            }, completeness: .complete)
    }

    /// The six columns of the core's index for a row: the four core properties where they hold a string and the
    /// type does not mark them `searchable: false`, the type's other searchable string properties in name order
    /// joined by a space, and the tags in byte order joined by a space.
    private static func columns(of item: Item, type: ItemType?) -> [String] {
        func string(_ name: String) -> String? {
            if case .string(let text)? = Properties.value(item.properties, name) { text } else { nil }
        }
        let declared = Dictionary(
            (type?.fields ?? []).map { (Array($0.name.utf8), $0) }, uniquingKeysWith: { $1 })
        func isString(_ field: TypeField) -> Bool { Properties.string(field.definition, "type") == "string" }
        func isSearchable(_ field: TypeField) -> Bool {
            if case .bool(false)? = Properties.value(field.definition, "searchable") { false } else { true }
        }
        let core = ["title", "body", "description", "name"]
        let coreColumns = core.map { name -> String in
            if let field = declared[Array(name.utf8)], isString(field), !isSearchable(field) { return "" }
            return string(name) ?? ""
        }
        let extra = (type?.fields ?? [])
            .filter { isString($0) && isSearchable($0) && !core.contains($0.name) }
            .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
            .compactMap { string($0.name) }
            .filter { !$0.isEmpty }
        let tags = item.tags.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return coreColumns + [extra.joined(separator: " "), tags.joined(separator: " ")]
    }

    // MARK: Query

    /// A query wholly inside double quotes is one phrase; otherwise each whitespace-separated word is quoted so
    /// nothing a person types is FTS5 syntax, and the last word also matches as a prefix. `nil` for a query with
    /// no word.
    private static func expression(of query: String) -> String? {
        let scalars = Array(query.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, isQuerySpace(scalars[start]) { start += 1 }
        while end > start, isQuerySpace(scalars[end - 1]) { end -= 1 }
        let trimmed = Array(scalars[start..<end])
        func quoted(_ scalars: some Sequence<Unicode.Scalar>) -> String {
            var text = "\""
            for scalar in scalars {
                if scalar == "\"" { text += "\"" }
                text.unicodeScalars.append(scalar)
            }
            return text + "\""
        }
        if trimmed.count > 2, trimmed.first == "\"", trimmed.last == "\"" {
            return quoted(trimmed.dropFirst().dropLast())
        }
        let words = trimmed.split(whereSeparator: isQuerySpace)
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { at, word in
            at == words.count - 1 ? quoted(word) + "*" : quoted(word)
        }.joined(separator: " ")
    }

    /// JavaScript's whitespace, as the server trims and splits: Unicode white space but not U+0085, and a
    /// byte-order mark.
    private static func isQuerySpace(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.properties.isWhitespace && scalar.value != 0x85) || scalar.value == 0xFEFF
    }

    /// The excerpt FTS5 cut, as HTML.
    ///
    /// The only markup is `<mark>` around matches. The text may hold the marker
    /// characters itself, so each opens only a closed mark and closes only an open one.
    private static func html(_ excerpt: String) -> String {
        var html = ""
        var open = false
        for character in excerpt.unicodeScalars {
            switch character {
            case "\u{E000}":
                if !open { html += "<mark>" }
                open = true
            case "\u{E001}":
                if open { html += "</mark>" }
                open = false
            case "&": html += "&amp;"
            case "<": html += "&lt;"
            case ">": html += "&gt;"
            case "\"": html += "&quot;"
            case "'": html += "&#39;"
            default: html.unicodeScalars.append(character)
            }
        }
        if open { html += "</mark>" }
        return html
    }
}

/// An in-memory SQLite database holding one FTS5 table laid out as the core's `items_fts`.
private final class FullTextIndex {
    private var database: OpaquePointer?

    init() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(":memory:", &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw FakeCopyError.unsupported(call: "search (no in-memory SQLite)")
        }
        do {
            try run(
                """
                CREATE VIRTUAL TABLE items_fts USING fts5 (
                  title, body, description, name, extra, tags, tokenize = 'porter unicode61');
                CREATE TABLE items (seq INTEGER PRIMARY KEY, id TEXT NOT NULL);
                CREATE TABLE allowed (seq INTEGER PRIMARY KEY);
                """)
        } catch {
            sqlite3_close(database)
            throw FakeCopyError.unsupported(call: "search (this SQLite has no FTS5 with the porter tokenizer)")
        }
    }

    deinit { sqlite3_close(database) }

    func fill(_ items: [Item], allowed: Set<String>, columns: (Item) -> [String]) throws {
        try run("BEGIN")
        let insert = try Statement(
            database,
            "INSERT INTO items_fts (rowid, title, body, description, name, extra, tags) VALUES (?, ?, ?, ?, ?, ?, ?)"
        )
        let named = try Statement(database, "INSERT INTO items (seq, id) VALUES (?, ?)")
        let permit = try Statement(database, "INSERT INTO allowed (seq) VALUES (?)")
        for (at, item) in items.enumerated() {
            let seq = Int64(at + 1)
            try insert.run([.integer(seq)] + columns(item).map { .text($0) })
            try named.run([.integer(seq), .text(item.id)])
            if allowed.contains(item.id) { try permit.run([.integer(seq)]) }
        }
        try run("COMMIT")
    }

    func rank(_ expression: String, open: String, close: String, limit: Int64) throws -> [(String, Double, String)] {
        let select = try Statement(
            database,
            """
            SELECT items.id, bm25(items_fts), snippet(items_fts, -1, ?2, ?3, '...', 32)
              FROM items_fts
              JOIN items ON items.seq = items_fts.rowid
              JOIN allowed ON allowed.seq = items.seq
             WHERE items_fts MATCH ?1
             ORDER BY bm25(items_fts), items.id
             LIMIT ?4
            """)
        return try select.rows([.text(expression), .text(open), .text(close), .integer(limit)]) { row in
            (row.text(0), row.real(1), row.text(2))
        }
    }

    private func run(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FakeCopyError.unsupported(call: "search (\(String(cString: sqlite3_errmsg(database))))")
        }
    }
}

private enum Bound {
    case integer(Int64)
    case text(String)
}

private final class Statement {
    private var statement: OpaquePointer?
    private let database: OpaquePointer?

    init(_ database: OpaquePointer?, _ sql: String) throws {
        self.database = database
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FakeCopyError.unsupported(call: "search (\(String(cString: sqlite3_errmsg(database))))")
        }
    }

    deinit { sqlite3_finalize(statement) }

    struct Row {
        let statement: OpaquePointer?
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }

    private func bind(_ values: [Bound]) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (at, value) in values.enumerated() {
            switch value {
            case .integer(let number): sqlite3_bind_int64(statement, Int32(at + 1), number)
            case .text(let text): sqlite3_bind_text(statement, Int32(at + 1), text, -1, transient)
            }
        }
    }

    func run(_ values: [Bound]) throws {
        bind(values)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FakeCopyError.unsupported(call: "search (\(String(cString: sqlite3_errmsg(database))))")
        }
    }

    func rows<Value>(_ values: [Bound], _ read: (Row) -> Value) throws -> [Value] {
        bind(values)
        var found: [Value] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: found.append(read(Row(statement: statement)))
            case SQLITE_DONE: return found
            default: throw FakeCopyError.unsupported(call: "search (\(String(cString: sqlite3_errmsg(database))))")
            }
        }
    }
}
#endif
