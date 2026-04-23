import Testing
import Foundation
import GRDB
@testable import MymeSDK

// MARK: - Helpers

/// Creates a temporary file path for a migration test database. The file is
/// created by GRDB when first opened; the test is responsible for cleanup.
private func tempDBPath() -> String {
    FileManager.default
        .temporaryDirectory
        .appendingPathComponent("myme-uuid-migration-\(UUID().uuidString).sqlite")
        .path
}

/// Opens a raw DatabasePool at `path`, creates the v1 schema, marks it as
/// applied in `grdb_migrations` (so LocalStore's migrator skips it and only
/// runs v3), then inserts the caller-supplied UUIDv4 rows.
///
/// Returns the path so the caller can open a `LocalStore` against it.
private func makeLegacyDatabase(
    path: String,
    itemIds: [String] = [],
    edgeSetups: [(id: String, sourceId: String, targetId: String)] = []
) throws {
    var config = Configuration()
    config.maximumReaderCount = 5
    let pool = try DatabasePool(path: path, configuration: config)

    try pool.write { db in
        // Build the v1 schema
        try db.execute(
            sql: """
                CREATE TABLE items (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'active',
                    properties_json TEXT NOT NULL DEFAULT '{}',
                    source TEXT NOT NULL DEFAULT '',
                    source_id TEXT,
                    origin TEXT NOT NULL DEFAULT 'user',
                    library INTEGER NOT NULL DEFAULT 0,
                    version INTEGER NOT NULL DEFAULT 1,
                    schema_version INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    timestamp TEXT NOT NULL,
                    device TEXT,
                    capture_latitude REAL,
                    capture_longitude REAL
                )
                """
        )
        try db.execute(
            sql: """
                CREATE TABLE edges (
                    id TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    edge_type TEXT NOT NULL,
                    properties_json TEXT NOT NULL DEFAULT '{}',
                    tenant_id TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
        )
        try db.execute(
            sql: """
                CREATE TABLE item_metadata (
                    item_id TEXT PRIMARY KEY,
                    tags_json TEXT NOT NULL DEFAULT '[]',
                    extensions_json TEXT NOT NULL DEFAULT '{}'
                )
                """
        )

        // Tell GRDB's migrator that v1 is done so LocalStore only runs v3.
        try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try db.execute(
            sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1_initial_schema')"
        )

        // Insert legacy UUIDv4 item rows.
        let now = "2024-01-01T00:00:00.000Z"
        for id in itemIds {
            try db.execute(
                sql: """
                    INSERT INTO items (id, type, state, properties_json, source, origin,
                                      library, version, schema_version,
                                      created_at, updated_at, timestamp)
                    VALUES (?, 'core.note', 'active', '{"body":"legacy note"}',
                            'test', 'user', 0, 1, 1, ?, ?, ?)
                    """,
                arguments: [id, now, now, now]
            )
            try db.execute(
                sql: "INSERT INTO item_metadata (item_id, tags_json, extensions_json) VALUES (?, '[]', '{}')",
                arguments: [id]
            )
        }

        // Insert legacy UUIDv4 edge rows.
        for setup in edgeSetups {
            try db.execute(
                sql: """
                    INSERT INTO edges (id, source_id, target_id, edge_type, properties_json,
                                      created_at, updated_at)
                    VALUES (?, ?, ?, 'in-thread', '{}', ?, ?)
                    """,
                arguments: [setup.id, setup.sourceId, setup.targetId, now, now]
            )
        }
    }
    // DatabasePool deinits cleanly here; WAL checkpoint happens automatically.
}

/// A known UUIDv4 (version nibble at position 14, 0-indexed = '4').
private func uuidv4() -> String {
    UUID().uuidString.lowercased()
}

/// Returns true if the given ID string has the UUIDv7 version nibble ('7') at
/// the canonical position. Mirrors the SQLite detection used in the migration.
private func isUUIDv7(_ id: String) -> Bool {
    let chars = Array(id.lowercased())
    guard chars.count == 36 else { return false }
    return chars[14] == "7"
}

private func isUUIDv4(_ id: String) -> Bool {
    let chars = Array(id.lowercased())
    guard chars.count == 36 else { return false }
    return chars[14] == "4"
}

// MARK: - Suite

@Suite("UUIDv4 → UUIDv7 migration (v3)")
struct UUIDv4MigrationTests {

    // MARK: Item rewrites

    @Test("Item with UUIDv4 ID is rewritten to UUIDv7 after opening LocalStore")
    func itemIdRewritten() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let legacyId = uuidv4()
        #expect(isUUIDv4(legacyId))

        try makeLegacyDatabase(path: path, itemIds: [legacyId])

        // Opening LocalStore triggers the v3 migration.
        let store = try LocalStore(path: path)
        let items = try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM items").map { $0["id"] as String }
        }

        #expect(items.count == 1)
        #expect(items[0] != legacyId, "old v4 ID should be gone")
        #expect(isUUIDv7(items[0]), "new ID should be UUIDv7")
    }

    @Test("Multiple items with UUIDv4 IDs are all rewritten independently")
    func multipleItemsRewritten() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let legacyIds = (0..<5).map { _ in uuidv4() }
        try makeLegacyDatabase(path: path, itemIds: legacyIds)

        let store = try LocalStore(path: path)
        let newIds = try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM items ORDER BY id").map {
                $0["id"] as String
            }
        }

        #expect(newIds.count == 5)
        // Every new ID is UUIDv7 and unique.
        for id in newIds {
            #expect(isUUIDv7(id))
        }
        #expect(Set(newIds).count == 5, "all new IDs should be distinct")
        // None of the old IDs survive.
        for old in legacyIds {
            #expect(!newIds.contains(old), "legacy ID \(old) should be gone")
        }
    }

    @Test("UUIDv7 item IDs are left untouched by the migration")
    func v7ItemsUnaffected() async throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Insert nothing with a v4 ID; open LocalStore so it creates its own
        // UUIDv7 rows after migration.
        try makeLegacyDatabase(path: path, itemIds: [])
        let store = try LocalStore(path: path)

        let input = CreateItemInput(type: "core.note", properties: ["body": .string("hello")])
        let item = try await store.createItem(input)
        #expect(isUUIDv7(item.id))

        let ids = try await store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM items").map { $0["id"] as String }
        }
        #expect(ids == [item.id])
    }

    // MARK: item_metadata cascade

    @Test("item_metadata.item_id is updated to match the rewritten item ID")
    func metadataItemIdUpdated() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let legacyId = uuidv4()
        try makeLegacyDatabase(path: path, itemIds: [legacyId])

        let store = try LocalStore(path: path)
        let newItemId = try store.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT id FROM items").map { $0["id"] as String }
        }
        let metadataItemId = try store.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT item_id FROM item_metadata").map {
                $0["item_id"] as String
            }
        }

        #expect(newItemId != nil)
        #expect(metadataItemId == newItemId, "item_metadata.item_id should match the new item ID")
    }

    // MARK: Edge rewrites

    @Test("Edge with UUIDv4 ID is rewritten to UUIDv7")
    func edgeIdRewritten() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let itemA = uuidv4()
        let itemB = uuidv4()
        let legacyEdgeId = uuidv4()

        try makeLegacyDatabase(
            path: path,
            itemIds: [itemA, itemB],
            edgeSetups: [(id: legacyEdgeId, sourceId: itemA, targetId: itemB)]
        )

        let store = try LocalStore(path: path)
        let edgeIds = try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM edges").map { $0["id"] as String }
        }

        #expect(edgeIds.count == 1)
        #expect(edgeIds[0] != legacyEdgeId)
        #expect(isUUIDv7(edgeIds[0]))
    }

    @Test("Edge source_id and target_id are updated when the referenced item IDs are rewritten")
    func edgeEndpointsUpdated() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let itemA = uuidv4()
        let itemB = uuidv4()
        let legacyEdgeId = uuidv4()

        try makeLegacyDatabase(
            path: path,
            itemIds: [itemA, itemB],
            edgeSetups: [(id: legacyEdgeId, sourceId: itemA, targetId: itemB)]
        )

        let store = try LocalStore(path: path)

        // Retrieve new item IDs.
        let newItemIds = try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM items ORDER BY id").map {
                $0["id"] as String
            }
        }
        #expect(newItemIds.count == 2)

        // Edge endpoints must match the new item IDs.
        guard let edgeRow = try store.pool.read(
            { db in try Row.fetchOne(db, sql: "SELECT source_id, target_id FROM edges") }
        ) else {
            Issue.record("Expected one edge row")
            return
        }
        let newSource = edgeRow["source_id"] as String
        let newTarget = edgeRow["target_id"] as String

        // Both should now be UUIDv7 and refer to real items.
        #expect(isUUIDv7(newSource))
        #expect(isUUIDv7(newTarget))
        #expect(newItemIds.contains(newSource), "source_id must match a migrated item")
        #expect(newItemIds.contains(newTarget), "target_id must match a migrated item")
        #expect(newSource != newTarget, "source and target should map to distinct items")
    }

    // MARK: Mixed v4/v7

    @Test("Mixed database: only UUIDv4 rows are rewritten; UUIDv7 rows survive intact")
    func mixedDatabase() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let v4Id = uuidv4()
        try makeLegacyDatabase(path: path, itemIds: [v4Id])

        // Also insert a UUIDv7 item directly via raw SQL to simulate a mixed DB.
        let v7Id = UUIDv7.generateString()
        let now = "2025-06-01T00:00:00.000Z"
        var config = Configuration()
        config.maximumReaderCount = 5
        let pool = try DatabasePool(path: path, configuration: config)
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO items (id, type, state, properties_json, source, origin,
                                      library, version, schema_version,
                                      created_at, updated_at, timestamp)
                    VALUES (?, 'core.note', 'active', '{}', 'test', 'user', 0, 1, 1, ?, ?, ?)
                    """,
                arguments: [v7Id, now, now, now]
            )
        }
        // DatabasePool deinit flushes before LocalStore opens below.
        _ = pool

        let store = try LocalStore(path: path)
        let ids = try store.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM items ORDER BY id").map {
                $0["id"] as String
            }
        }

        #expect(ids.count == 2)
        #expect(ids.contains(v7Id), "the existing UUIDv7 row should survive unchanged")
        #expect(!ids.contains(v4Id), "the UUIDv4 row should be gone")
        #expect(ids.allSatisfy { isUUIDv7($0) }, "every ID in the table should now be UUIDv7")
    }

    // MARK: Fresh install (no-op)

    @Test("Migration is a no-op on a fresh database with no legacy rows")
    func freshInstallNoOp() throws {
        // LocalStore(path:) with no pre-existing DB: v3 runs on an empty
        // database and should produce no errors.
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: Never.self) { try LocalStore(path: path) }
    }
}
