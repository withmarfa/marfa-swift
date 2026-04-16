import Foundation
import GRDB

/// Persistent local mirror of the Myme data model backed by SQLite (GRDB).
///
/// Used in two modes:
/// - **Pure-local** — `MymeClient.local(path:)`. No server; all namespace
///   calls resolve against this store. Ideal for on-device-only apps, tests,
///   and offline-first prototyping.
/// - **Synced** — `MymeClient.synced(url:apiKey:storePath:)`. Writes go to
///   the store immediately, then queue to replay against the server. Reads
///   are served locally; the sync engine keeps the store fresh via SSE.
///
/// The actor isolates all SQLite access. `DatabasePool` is opened in WAL mode,
/// allowing concurrent reads while a write is in flight.
public actor LocalStore {

    // MARK: - Internal state

    /// Shared `DatabasePool` — nonisolated so the reactive and sync layers
    /// (`MymeStore`, `MutationQueue`, `SyncEngine`) can construct observations
    /// and sibling writers without crossing the actor boundary for every read.
    /// `DatabasePool` is `Sendable` (GRDB 7+), so this is safe.
    nonisolated let pool: DatabasePool

    /// ISO 8601 timestamp with fractional seconds, matching the wire format
    /// used by the server. `Date.ISO8601FormatStyle` is a `Sendable` value type,
    /// so this avoids the concurrency constraints that apply to
    /// `ISO8601DateFormatter` under Swift 6 strict mode.
    private static func iso8601(_ date: Date) -> String {
        date.ISO8601Format(.init(includingFractionalSeconds: true))
    }

    // MARK: - Init

    /// Opens (or creates) the SQLite database at `path` and runs migrations.
    ///
    /// Pass `:memory:` for an ephemeral database — useful in tests. `DatabasePool`
    /// requires file-backed storage for WAL mode, so `:memory:` is transparently
    /// mapped to a unique file under the OS temporary directory. The file is
    /// not explicitly cleaned up; the OS evicts stale temp files.
    public init(path: String) throws {
        let resolvedPath: String
        if path == ":memory:" {
            resolvedPath =
                FileManager.default
                .temporaryDirectory
                .appendingPathComponent("myme-\(UUID().uuidString).sqlite")
                .path
        } else {
            resolvedPath = path
        }
        var config = Configuration()
        config.maximumReaderCount = 5
        pool = try DatabasePool(path: resolvedPath, configuration: config)
        var migrator = DatabaseMigrator()
        LocalStore.registerMigrations(into: &migrator)
        try migrator.migrate(pool)
    }

    // MARK: - Schema migrations

    private static func registerMigrations(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial_schema") { db in
            try db.create(table: "items") { t in
                t.primaryKey("id", .text)
                t.column("type", .text).notNull()
                t.column("state", .text).notNull().defaults(to: "active")
                t.column("properties_json", .text).notNull().defaults(to: "{}")
                t.column("source", .text).notNull().defaults(to: "")
                t.column("source_id", .text)
                t.column("origin", .text).notNull().defaults(to: "user")
                t.column("library", .boolean).notNull().defaults(to: false)
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("schema_version", .integer).notNull().defaults(to: 1)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("timestamp", .text).notNull()
                t.column("device", .text)
                t.column("capture_latitude", .double)
                t.column("capture_longitude", .double)
            }

            try db.create(table: "edges") { t in
                t.primaryKey("id", .text)
                t.column("source_id", .text).notNull()
                t.column("target_id", .text).notNull()
                t.column("edge_type", .text).notNull()
                t.column("properties_json", .text).notNull().defaults(to: "{}")
                t.column("tenant_id", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            try db.create(table: "item_metadata") { t in
                t.primaryKey("item_id", .text)
                t.column("tags_json", .text).notNull().defaults(to: "[]")
                t.column("extensions_json", .text).notNull().defaults(to: "{}")
            }

            // Indexes for common access patterns
            try db.create(
                index: "idx_items_type_state",
                on: "items",
                columns: ["type", "state"]
            )
            try db.create(
                index: "idx_items_updated_at",
                on: "items",
                columns: ["updated_at"]
            )
            try db.create(
                index: "idx_edges_source",
                on: "edges",
                columns: ["source_id", "edge_type"]
            )
            try db.create(
                index: "idx_edges_target",
                on: "edges",
                columns: ["target_id", "edge_type"]
            )
        }
    }

    // MARK: - Helpers

    private func now() -> String {
        LocalStore.iso8601(Date())
    }

    private func newId() -> String {
        UUID().uuidString.lowercased()
    }

    // MARK: - Item CRUD

    /// Creates an item from the given input. Assigns a new UUID as the server
    /// ID since there is no server in pure-local mode.
    func createItem(_ input: CreateItemInput) throws -> Item {
        let now = now()
        let id = newId()
        let item = Item(
            captureLatitude: input.captureLatitude,
            captureLongitude: input.captureLongitude,
            createdAt: input.timestamp ?? now,
            device: input.device,
            edges: nil,
            id: id,
            library: input.library ?? false,
            origin: input.origin ?? .user,
            properties: input.properties,
            schemaVersion: 1,
            source: input.source ?? "local",
            sourceId: input.sourceId,
            state: input.state ?? .active,
            timestamp: input.timestamp ?? now,
            type: input.type,
            updatedAt: now,
            version: 1
        )
        let record = try ItemRecord.from(item)
        try pool.write { db in
            try record.insert(db)
        }
        return item
    }

    /// Fetches a single item by ID. Throws ``NotFoundError`` if absent.
    func fetchItem(id: String) throws -> Item {
        let record = try pool.read { db in
            try ItemRecord.filter(Column("id") == id).fetchOne(db)
        }
        guard let record else {
            throw NotFoundError(message: "Item not found: \(id)")
        }
        return try record.toItem()
    }

    /// Fetches items, applying optional filters. Returns a ``PaginatedResult``
    /// with `hasMore: false` — local stores don't cursor-paginate.
    func fetchItems(filters: ListFilters?) throws -> PaginatedResult<Item> {
        let records = try pool.read { db in
            var request = ItemRecord.all()
            if let type = filters?.type {
                request = request.filter(Column("type") == type)
            }
            if let state = filters?.state {
                request = request.filter(Column("state") == state.rawValue)
            }
            if let since = filters?.since {
                request = request.filter(Column("updated_at") >= since)
            }
            if let until = filters?.until {
                request = request.filter(Column("updated_at") <= until)
            }
            if let limit = filters?.limit {
                request = request.limit(limit)
            }
            // Default sort: newest first
            let direction = filters?.direction
            let sortColumn = Column(filters?.sort?.rawValue ?? "updated_at")
            if direction == .ascending {
                request = request.order(sortColumn.asc)
            } else {
                request = request.order(sortColumn.desc)
            }
            return try request.fetchAll(db)
        }
        let items = try records.map { try $0.toItem() }
        return PaginatedResult(data: items, cursor: nil, hasMore: false)
    }

    /// Updates an item's properties. Increments the version and sets `updated_at`.
    @discardableResult
    func updateItem(id: String, properties: [String: JSONValue]) throws -> Item {
        let now = now()
        let existing = try fetchItem(id: id)
        let updated = Item(
            captureLatitude: existing.captureLatitude,
            captureLongitude: existing.captureLongitude,
            createdAt: existing.createdAt,
            device: existing.device,
            edges: nil,
            id: existing.id,
            library: existing.library,
            origin: existing.origin,
            properties: properties,
            schemaVersion: existing.schemaVersion,
            source: existing.source,
            sourceId: existing.sourceId,
            state: existing.state,
            timestamp: existing.timestamp,
            type: existing.type,
            updatedAt: now,
            version: existing.version + 1
        )
        let record = try ItemRecord.from(updated)
        try pool.write { db in
            try record.update(db)
        }
        return updated
    }

    /// Sets the item's state to `trashed` (soft delete).
    func trashItem(id: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE items SET state = 'trashed', updated_at = ? WHERE id = ?",
                arguments: [now(), id]
            )
        }
    }

    /// Sets the item's state to `active` (restores from trash).
    func restoreItem(id: String) throws -> Item {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE items SET state = 'active', updated_at = ? WHERE id = ?",
                arguments: [now(), id]
            )
        }
        return try fetchItem(id: id)
    }

    /// Transitions the item to a new lifecycle state.
    func transitionItem(id: String, to state: String) throws -> Item {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE items SET state = ?, updated_at = ? WHERE id = ?",
                arguments: [state, now(), id]
            )
        }
        return try fetchItem(id: id)
    }

    /// Returns item counts grouped by state.
    func itemStats() throws -> [String: Int] {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT state, COUNT(*) as count FROM items GROUP BY state"
            )
            return Dictionary(
                uniqueKeysWithValues: rows.map {
                    ($0["state"] as String, $0["count"] as Int)
                })
        }
    }

    /// Permanently removes the item and its metadata.
    func purgeItem(id: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM item_metadata WHERE item_id = ?", arguments: [id])
        }
    }

    /// Stores (insert or replace) a raw item — used by the sync engine.
    func upsertItem(_ item: Item) throws {
        let record = try ItemRecord.from(item)
        try pool.write { db in
            try record.save(db)
        }
    }

    // MARK: - Edge CRUD

    /// Creates a new edge between two items.
    func createEdge(
        source: String,
        target: String,
        edgeType: String,
        properties: [String: JSONValue]?
    ) throws -> Edge {
        let now = now()
        let edge = Edge(
            createdAt: now,
            edgeType: edgeType,
            id: newId(),
            properties: properties ?? [:],
            sourceId: source,
            targetId: target,
            tenantId: nil,
            updatedAt: now
        )
        let record = try EdgeRecord.from(edge)
        try pool.write { db in
            try record.insert(db)
        }
        return edge
    }

    /// Fetches a single edge by ID. Throws ``NotFoundError`` if absent.
    func fetchEdge(id: String) throws -> Edge {
        let record = try pool.read { db in
            try EdgeRecord.filter(Column("id") == id).fetchOne(db)
        }
        guard let record else {
            throw NotFoundError(message: "Edge not found: \(id)")
        }
        return try record.toEdge()
    }

    /// Lists edges where `source_id == sourceId`, optionally filtered by type.
    func fetchEdgesFromSource(
        sourceId: String,
        edgeType: String?,
        limit: Int?
    ) throws -> PaginatedResult<Edge> {
        let records = try pool.read { db in
            var request = EdgeRecord.filter(Column("source_id") == sourceId)
            if let edgeType {
                request = request.filter(Column("edge_type") == edgeType)
            }
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }
        let edges = try records.map { try $0.toEdge() }
        return PaginatedResult(data: edges, cursor: nil, hasMore: false)
    }

    /// Lists edges where `target_id == targetId`, optionally filtered by type.
    func fetchEdgesToTarget(
        targetId: String,
        edgeType: String?,
        limit: Int?
    ) throws -> PaginatedResult<Edge> {
        let records = try pool.read { db in
            var request = EdgeRecord.filter(Column("target_id") == targetId)
            if let edgeType {
                request = request.filter(Column("edge_type") == edgeType)
            }
            if let limit { request = request.limit(limit) }
            return try request.fetchAll(db)
        }
        let edges = try records.map { try $0.toEdge() }
        return PaginatedResult(data: edges, cursor: nil, hasMore: false)
    }

    /// Updates an edge's properties.
    func updateEdge(id: String, properties: [String: JSONValue]) throws -> Edge {
        let existing = try fetchEdge(id: id)
        let updated = Edge(
            createdAt: existing.createdAt,
            edgeType: existing.edgeType,
            id: existing.id,
            properties: properties,
            sourceId: existing.sourceId,
            targetId: existing.targetId,
            tenantId: existing.tenantId,
            updatedAt: now()
        )
        let record = try EdgeRecord.from(updated)
        try pool.write { db in
            try record.update(db)
        }
        return updated
    }

    /// Deletes an edge by ID.
    func deleteEdge(id: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM edges WHERE id = ?", arguments: [id])
        }
    }

    /// Stores (insert or replace) a raw edge — used by the sync engine.
    func upsertEdge(_ edge: Edge) throws {
        let record = try EdgeRecord.from(edge)
        try pool.write { db in
            try record.save(db)
        }
    }

    // MARK: - Metadata CRUD

    /// Fetches metadata for an item. Returns empty metadata if none exists.
    func fetchMetadata(itemId: String) throws -> Metadata {
        let record = try pool.read { db in
            try MetadataRecord.filter(Column("item_id") == itemId).fetchOne(db)
        }
        return try record?.toMetadata() ?? Metadata(extensions: [:], itemId: itemId, tags: [])
    }

    /// Replaces all metadata for an item.
    @discardableResult
    func setMetadata(itemId: String, input: MetadataInput) throws -> Metadata {
        let metadata = Metadata(
            extensions: [:],
            itemId: itemId,
            tags: input.tags ?? []
        )
        let record = try MetadataRecord.from(metadata)
        try pool.write { db in
            try record.save(db)
        }
        return metadata
    }

    /// Merges (union) metadata with existing values.
    @discardableResult
    func mergeMetadata(itemId: String, input: MetadataInput) throws -> Metadata {
        let existing = try fetchMetadata(itemId: itemId)
        let merged = Metadata(
            extensions: existing.extensions,
            itemId: itemId,
            tags: Array(Set(existing.tags + (input.tags ?? [])).sorted())
        )
        let record = try MetadataRecord.from(merged)
        try pool.write { db in
            try record.save(db)
        }
        return merged
    }

    /// Adds tags to an item (union with existing tags).
    @discardableResult
    func addTags(itemId: String, tags: [String]) throws -> Metadata {
        return try mergeMetadata(itemId: itemId, input: MetadataInput(tags: tags))
    }

    /// Removes a single tag from an item.
    func removeTag(itemId: String, tag: String) throws {
        let existing = try fetchMetadata(itemId: itemId)
        let updated = Metadata(
            extensions: existing.extensions,
            itemId: itemId,
            tags: existing.tags.filter { $0 != tag }
        )
        let record = try MetadataRecord.from(updated)
        try pool.write { db in
            try record.save(db)
        }
    }

    // MARK: - Extension CRUD

    /// Writes data to a namespaced extension on an item, merging it into any
    /// existing extensions map. Returns the full extensions dictionary.
    @discardableResult
    func setExtension(
        itemId: String,
        namespace: String,
        data: [String: JSONValue]
    ) throws -> [String: [String: JSONValue]] {
        let existing = try fetchMetadata(itemId: itemId)
        var map = Self.unwrapExtensions(existing.extensions)
        map[namespace] = data
        let merged = Metadata(
            extensions: Self.wrapExtensions(map),
            itemId: itemId,
            tags: existing.tags
        )
        let record = try MetadataRecord.from(merged)
        try pool.write { db in
            try record.save(db)
        }
        return map
    }

    /// Removes a namespaced extension from an item.
    func deleteExtension(itemId: String, namespace: String) throws {
        let existing = try fetchMetadata(itemId: itemId)
        var map = Self.unwrapExtensions(existing.extensions)
        map.removeValue(forKey: namespace)
        let merged = Metadata(
            extensions: Self.wrapExtensions(map),
            itemId: itemId,
            tags: existing.tags
        )
        let record = try MetadataRecord.from(merged)
        try pool.write { db in
            try record.save(db)
        }
    }

    /// Returns all extension namespaces for an item.
    func fetchExtensions(itemId: String) throws -> [String: [String: JSONValue]] {
        Self.unwrapExtensions(try fetchMetadata(itemId: itemId).extensions)
    }

    /// Returns a single extension namespace for an item, or `nil` if absent.
    func fetchExtension(itemId: String, namespace: String) throws -> [String: JSONValue]? {
        try fetchExtensions(itemId: itemId)[namespace]
    }

    // Each namespace's stored value is an object. The wire type models the
    // extensions map as `[String: JSONValue]` (any value), but in practice
    // every namespace holds a dictionary. These helpers unwrap/rewrap between
    // the two shapes without losing type information.
    private static func unwrapExtensions(
        _ extensions: [String: JSONValue]
    ) -> [String: [String: JSONValue]] {
        var map: [String: [String: JSONValue]] = [:]
        for (namespace, value) in extensions {
            if case .dictionary(let dict) = value {
                map[namespace] = dict
            }
        }
        return map
    }

    private static func wrapExtensions(
        _ map: [String: [String: JSONValue]]
    ) -> [String: JSONValue] {
        var wrapped: [String: JSONValue] = [:]
        for (namespace, dict) in map {
            wrapped[namespace] = .dictionary(dict)
        }
        return wrapped
    }
}
