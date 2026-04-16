import Foundation
import GRDB

// MARK: - Pending mutation record

/// A serialised SDK write operation awaiting server replay.
struct PendingMutationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "pending_mutations"

    enum Kind: String, Codable {
        case createItem, updateItem, deleteItem, restoreItem, transitionItem, purgeItem
        case createEdge, updateEdge, deleteEdge
        case setMetadata, mergeMetadata, addTags, removeTag
        case setExtension, deleteExtension
    }

    var id: String          // UUID of this mutation record
    var kind: Kind
    var payloadJson: String // JSON-encoded payload (type depends on kind)
    var sourceId: String?   // UUIDv7 sourceId for create idempotency (items only)
    var localId: String?    // local item/edge ID for reference
    var createdAt: String
    var attemptCount: Int
    var lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case payloadJson = "payload_json"
        case sourceId = "source_id"
        case localId = "local_id"
        case createdAt = "created_at"
        case attemptCount = "attempt_count"
        case lastError = "last_error"
    }
}

// MARK: - Typed payloads

/// Payload stored for a `createItem` mutation.
struct CreateItemPayload: Codable, Sendable {
    let input: CreateItemInput
}

/// Payload stored for an `updateItem` mutation.
struct UpdateItemPayload: Codable, Sendable {
    let id: String
    let properties: [String: JSONValue]
}

/// Payload for mutations that just need an item/edge ID.
struct IDPayload: Codable, Sendable {
    let id: String
}

/// Payload for `transitionItem`.
struct TransitionPayload: Codable, Sendable {
    let id: String
    let state: String
}

/// Payload for `createEdge`.
struct CreateEdgePayload: Codable, Sendable {
    let source: String
    let target: String
    let edgeType: String
    let properties: [String: JSONValue]?
}

/// Payload for `updateEdge`.
struct UpdateEdgePayload: Codable, Sendable {
    let id: String
    let properties: [String: JSONValue]
}

/// Payload for `setMetadata` and `mergeMetadata`.
struct MetadataPayload: Codable, Sendable {
    let itemId: String
    let input: MetadataInput
}

/// Payload for `addTags`.
struct AddTagsPayload: Codable, Sendable {
    let itemId: String
    let tags: [String]
}

/// Payload for `removeTag`.
struct RemoveTagPayload: Codable, Sendable {
    let itemId: String
    let tag: String
}

/// Payload for `setExtension`.
struct SetExtensionPayload: Codable, Sendable {
    let itemId: String
    let namespace: String
    let data: [String: JSONValue]
}

/// Payload for `deleteExtension`.
struct DeleteExtensionPayload: Codable, Sendable {
    let itemId: String
    let namespace: String
}

// MARK: - MutationQueue actor

/// Durable queue of pending server writes.
///
/// Mutations are appended immediately in the namespace's local-write path and
/// dequeued by ``SyncEngine`` when the client goes online. Idempotency for
/// item creates is enforced via the `source_id` field: the server returns 409
/// `duplicate_source` when the (source, sourceId) pair already exists, which
/// the engine treats as a successful no-op.
public actor MutationQueue {

    private let pool: DatabasePool
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Init

    /// Shares the same `DatabasePool` as ``LocalStore`` so mutations are
    /// committed in the same WAL journal.
    init(pool: DatabasePool) throws {
        self.pool = pool
        var migrator = DatabaseMigrator()
        MutationQueue.registerMigrations(into: &migrator)
        try migrator.migrate(pool)
    }

    // MARK: - Schema

    private static func registerMigrations(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_mutation_queue") { db in
            try db.create(table: "pending_mutations", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("payload_json", .text).notNull()
                t.column("source_id", .text)
                t.column("local_id", .text)
                t.column("created_at", .text).notNull()
                t.column("attempt_count", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
            }
            try db.create(table: "sync_state", ifNotExists: true) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
    }

    // MARK: - Enqueue helpers

    private func enqueue(
        kind: PendingMutationRecord.Kind,
        payload: some Encodable & Sendable,
        sourceId: String? = nil,
        localId: String? = nil
    ) throws {
        let data = try MutationQueue.encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalStoreError.encodingFailure("mutation payload")
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let record = PendingMutationRecord(
            id: UUID().uuidString.lowercased(),
            kind: kind,
            payloadJson: json,
            sourceId: sourceId,
            localId: localId,
            createdAt: now,
            attemptCount: 0,
            lastError: nil
        )
        try pool.write { db in
            try record.insert(db)
        }
    }

    // MARK: - Enqueue public API

    func enqueueCreateItem(_ input: CreateItemInput, localId: String) throws {
        let sourceId = input.sourceId ?? localId
        try enqueue(
            kind: .createItem,
            payload: CreateItemPayload(input: input),
            sourceId: sourceId,
            localId: localId
        )
    }

    func enqueueUpdateItem(id: String, properties: [String: JSONValue]) throws {
        try enqueue(kind: .updateItem, payload: UpdateItemPayload(id: id, properties: properties), localId: id)
    }

    func enqueueDeleteItem(id: String) throws {
        try enqueue(kind: .deleteItem, payload: IDPayload(id: id), localId: id)
    }

    func enqueueRestoreItem(id: String) throws {
        try enqueue(kind: .restoreItem, payload: IDPayload(id: id), localId: id)
    }

    func enqueueTransitionItem(id: String, to state: String) throws {
        try enqueue(kind: .transitionItem, payload: TransitionPayload(id: id, state: state), localId: id)
    }

    func enqueuePurgeItem(id: String) throws {
        try enqueue(kind: .purgeItem, payload: IDPayload(id: id), localId: id)
    }

    func enqueueCreateEdge(source: String, target: String, edgeType: String, properties: [String: JSONValue]?, localEdgeId: String) throws {
        try enqueue(
            kind: .createEdge,
            payload: CreateEdgePayload(source: source, target: target, edgeType: edgeType, properties: properties),
            localId: localEdgeId
        )
    }

    func enqueueUpdateEdge(id: String, properties: [String: JSONValue]) throws {
        try enqueue(kind: .updateEdge, payload: UpdateEdgePayload(id: id, properties: properties), localId: id)
    }

    func enqueueDeleteEdge(id: String) throws {
        try enqueue(kind: .deleteEdge, payload: IDPayload(id: id), localId: id)
    }

    func enqueueSetMetadata(itemId: String, input: MetadataInput) throws {
        try enqueue(kind: .setMetadata, payload: MetadataPayload(itemId: itemId, input: input), localId: itemId)
    }

    func enqueueMergeMetadata(itemId: String, input: MetadataInput) throws {
        try enqueue(kind: .mergeMetadata, payload: MetadataPayload(itemId: itemId, input: input), localId: itemId)
    }

    func enqueueAddTags(itemId: String, tags: [String]) throws {
        try enqueue(kind: .addTags, payload: AddTagsPayload(itemId: itemId, tags: tags), localId: itemId)
    }

    func enqueueRemoveTag(itemId: String, tag: String) throws {
        try enqueue(kind: .removeTag, payload: RemoveTagPayload(itemId: itemId, tag: tag), localId: itemId)
    }

    func enqueueSetExtension(itemId: String, namespace: String, data: [String: JSONValue]) throws {
        try enqueue(
            kind: .setExtension,
            payload: SetExtensionPayload(itemId: itemId, namespace: namespace, data: data),
            localId: itemId
        )
    }

    func enqueueDeleteExtension(itemId: String, namespace: String) throws {
        try enqueue(
            kind: .deleteExtension,
            payload: DeleteExtensionPayload(itemId: itemId, namespace: namespace),
            localId: itemId
        )
    }

    // MARK: - Dequeue / drain

    /// Returns all pending mutations in creation order.
    func fetchAll() throws -> [PendingMutationRecord] {
        try pool.read { db in
            try PendingMutationRecord
                .order(Column("created_at").asc)
                .fetchAll(db)
        }
    }

    /// Removes a successfully replayed mutation.
    func remove(id: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM pending_mutations WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Records a failed replay attempt.
    func recordFailure(id: String, error: String) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                     UPDATE pending_mutations
                        SET attempt_count = attempt_count + 1,
                            last_error = ?
                      WHERE id = ?
                     """,
                arguments: [error, id]
            )
        }
    }

    /// Returns `true` if there are any pending mutations.
    var isEmpty: Bool {
        get throws {
            try pool.read { db in
                try PendingMutationRecord.fetchCount(db) == 0
            }
        }
    }

    // MARK: - Sync state (Last-Event-ID cursor)

    func loadSyncState(key: String) throws -> String? {
        try pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT value FROM sync_state WHERE key = ?",
                arguments: [key]
            ).map { $0["value"] as String }
        }
    }

    func saveSyncState(key: String, value: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }
}
