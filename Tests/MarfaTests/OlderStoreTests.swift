import Foundation
import Marfa
import SQLite3
import Testing

/// A store an earlier build of the core made is refused, never discarded.
///
/// The earlier store is made from one of this build's: its queue table is
/// given back the write kind `merge_metadata`, which earlier builds queued and
/// this one cannot send, and one of its writes takes that kind.
@Suite(.timeLimit(.minutes(1)))
struct OlderStore {
    @Test func aStoreAnEarlierBuildMadeIsRefusedWithItsUnsentWritesAndKept() async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        let id = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["body": "kept"])).itemId)
        _ = try await copy.tags.add("kept", to: id)
        await copy.close()
        try Self.execute(
            store,
            """
            PRAGMA writable_schema = ON;
            UPDATE sqlite_master SET sql = replace(sql, '''replace_metadata'',', '''replace_metadata'', ''merge_metadata'',')
              WHERE type = 'table' AND name = 'queue';
            """)
        try Self.execute(store, "UPDATE queue SET kind = 'merge_metadata' WHERE kind = 'add_tag'")

        await #expect {
            _ = try await WorkingCopy.open(store: store)
        } throws: { error in
            guard case Marfa.MarfaError.wrongSchema(let path, let reason, let unsent, let message) = error else {
                return false
            }
            return path.hasSuffix(store.lastPathComponent)
                && reason.contains("its table queue is not the shape this build reads")
                && reason.contains("its queue holds 1 write of kind merge_metadata, which this build cannot send")
                && unsent == 2
                && message.contains("It holds 2 writes the server has not taken")
        }
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(try Self.count(store, "SELECT COUNT(*) FROM queue") == 2)
        #expect(try Self.count(store, "SELECT COUNT(*) FROM items WHERE id = '\(id)'") == 1)
    }

    /// Runs statements on the store behind the copy's back, as an earlier build would have left it.
    static func execute(_ store: URL, _ statements: String) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(store.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, statements, nil, nil, nil) == SQLITE_OK)
    }

    static func count(_ store: URL, _ query: String) throws -> Int64 {
        var database: OpaquePointer?
        try #require(sqlite3_open_v2(store.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }
}
