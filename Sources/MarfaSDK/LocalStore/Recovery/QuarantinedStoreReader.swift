import Foundation
import SQLite3

/// Reads the tables only the device holds out of a quarantined store, using
/// SQLite directly.
///
/// **The ORM is the one component guaranteed unable to read this file.** The
/// store was set aside because its entity shapes match no model this build
/// carries, which is a refusal by the object-graph layer and says nothing
/// about the database underneath it: the file opens, the tables are there, the
/// rows are intact. So the salvage goes under SwiftData rather than through it.
///
/// Four tables are read, and the choice is not arbitrary — they are the ones
/// whose contents exist nowhere else. Items, edges and metadata all come back
/// from the server on the next import; a queued write, the log of one the
/// server refused, the cursor saying what this device has already seen, and
/// the descriptors of blobs waiting to upload do not.
///
/// Column names are Core Data's, which is why they are recovered from the file
/// rather than assumed. The columns a `SELECT *` actually returns are read
/// off the statement and the `Z`-prefixed, upper-cased names mapped back to
/// the property names the SDK uses where one matches; anything unrecognized
/// is kept under its own name rather than dropped. A store written by a build
/// that named its columns differently therefore still yields readable rows.
enum QuarantinedStoreReader {

    /// The tables worth salvaging, keyed by the name the sidecar gives them.
    ///
    /// The property lists are what the columns are mapped back to. They are
    /// frozen deliberately: this reads stores written by builds that no longer
    /// exist, so tracking the live models would make the mapping wrong for
    /// exactly the files it is for.
    static let salvaged: [(sidecarKey: String, table: String, properties: [String])] = [
        (
            "pendingMutations", "ZPENDINGMUTATIONMODEL",
            [
                "id", "kindRaw", "payloadJson", "sourceId", "localId",
                "createdAt", "attemptCount", "lastError", "stateRaw",
            ]
        ),
        (
            "droppedMutations", "ZDROPPEDMUTATIONMODEL",
            [
                "id", "kindRaw", "payloadJson", "localId", "enqueuedAt",
                "droppedAt", "attemptCount", "errorStatus", "errorCode",
                "errorMessage", "errorDetailsJson",
            ]
        ),
        ("syncState", "ZSYNCSTATEMODEL", ["key", "value"]),
        ("pendingBlobs", "ZPENDINGBLOBMODEL", ["contentHash", "mimeType", "data"]),
    ]

    /// Core Data's own bookkeeping columns. Present in every table, meaningful
    /// only to the object graph that is not being rebuilt.
    private static let bookkeeping: Set<String> = ["Z_PK", "Z_ENT", "Z_OPT"]

    struct Extraction {
        /// Rows per sidecar key. A table the store does not have is absent
        /// rather than empty, so a reader can tell "no queued writes" from
        /// "no such table".
        let tables: [String: [[String: JSONValue]]]

        func rows(_ key: String) -> [[String: JSONValue]] { tables[key] ?? [] }
    }

    enum ReadError: Error, CustomStringConvertible {
        case open(String)
        case query(table: String, message: String)

        var description: String {
            switch self {
            case .open(let message): return "could not open the quarantined store: \(message)"
            case .query(let table, let message): return "could not read \(table): \(message)"
            }
        }
    }

    static func read(storeAt url: URL) throws -> Extraction {
        var handle: OpaquePointer?
        // Read-write, without `SQLITE_OPEN_CREATE`, and the pair is deliberate.
        //
        // Read-only would be the instinct and does not work here: a store in
        // WAL mode needs its shared-memory index to be readable at all, a
        // read-only connection cannot create one, and the first query comes
        // back `unable to open database file` — measured against a real store,
        // not reasoned about. So the alternatives are writing to the file or
        // not reading the newest rows in it, since a `-wal` holds transactions
        // the database file does not. It writes. What it writes to is a
        // quarantined copy that nothing else will open again.
        //
        // Never `SQLITE_OPEN_CREATE`: a path that turns out not to hold a
        // database has to fail, not become an empty one.
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard status == SQLITE_OK, let database = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close(handle)
            throw ReadError.open(message)
        }
        defer { sqlite3_close(database) }

        var tables: [String: [[String: JSONValue]]] = [:]
        for entry in salvaged {
            guard try tableExists(entry.table, in: database) else { continue }
            tables[entry.sidecarKey] = try rows(
                of: entry.table,
                mappedBy: propertyNamesByColumn(entry.properties),
                in: database
            )
        }
        return Extraction(tables: tables)
    }

    // MARK: - Internals

    /// `attemptCount` is stored as `ZATTEMPTCOUNT`, so the mapping back is a
    /// case-insensitive match on the un-prefixed name rather than a guess at
    /// where the humps were.
    private static func propertyNamesByColumn(_ properties: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: properties.map { ("Z" + $0.uppercased(), $0) })
    }

    private static func tableExists(_ table: String, in database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError.query(table: table, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: SQLite copies the bytes rather than holding this
        // Swift string's storage past the call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, table, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func rows(
        of table: String,
        mappedBy names: [String: String],
        in database: OpaquePointer
    ) throws -> [[String: JSONValue]] {
        var statement: OpaquePointer?
        // The table name is one of this file's own constants, never input.
        guard sqlite3_prepare_v2(database, "SELECT * FROM \(table)", -1, &statement, nil) == SQLITE_OK
        else {
            throw ReadError.query(table: table, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var out: [[String: JSONValue]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: JSONValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let raw = sqlite3_column_name(statement, index) else { continue }
                let column = String(cString: raw)
                guard !bookkeeping.contains(column) else { continue }
                row[names[column] ?? column] = value(of: statement, at: index)
            }
            out.append(row)
        }
        return out
    }

    /// One column's value as JSON.
    ///
    /// A blob becomes its byte count rather than its bytes. The sidecar is a
    /// text artifact meant to be read, a queued upload can be megabytes, and
    /// the bytes have not gone anywhere — they are in the quarantined store,
    /// which is the reason it is kept.
    private static func value(of statement: OpaquePointer?, at index: Int32) -> JSONValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .int(Int(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .string(String(cString: text))
        case SQLITE_BLOB:
            return .string("<\(sqlite3_column_bytes(statement, index)) bytes, in the quarantined store>")
        default:
            return .null
        }
    }
}
