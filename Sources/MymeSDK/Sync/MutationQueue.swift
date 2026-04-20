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

    var id: String  // UUID of this mutation record
    var kind: Kind
    var payloadJson: String  // JSON-encoded payload (type depends on kind)
    var sourceId: String?  // UUIDv7 sourceId for create idempotency (items only)
    var localId: String?  // local item/edge ID for reference
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
///
/// `version` and `conflict` capture the per-call conflict context so a
/// replay can apply the same strategy the caller chose. The `.callback`
/// resolver closure is not serialisable — on replay, `.callback` degrades
/// to `.auto`. `library` mirrors the server's separate library-axis flip
/// on `PATCH /items/:id`.
struct UpdateItemPayload: Codable, Sendable {
    let id: String
    let properties: [String: JSONValue]
    var version: Int?
    var conflict: ConflictStrategy?
    var library: Bool?
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
        // `Date.ISO8601FormatStyle` is `Sendable`; `ISO8601DateFormatter` is
        // not, so creating one here would violate Swift 6 strict concurrency
        // on every enqueue even though it works at runtime.
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
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

    func enqueueUpdateItem(
        id: String,
        properties: [String: JSONValue],
        version: Int? = nil,
        conflict: ConflictStrategy? = nil,
        library: Bool? = nil
    ) throws {
        try enqueue(
            kind: .updateItem,
            payload: UpdateItemPayload(
                id: id,
                properties: properties,
                version: version,
                conflict: conflict,
                library: library
            ),
            localId: id
        )
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

    func enqueueCreateEdge(
        source: String, target: String, edgeType: String, properties: [String: JSONValue]?, localEdgeId: String
    ) throws {
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

    /// Clears a persisted `sync_state` key. Used by the `catchup_too_old`
    /// handler to reset the `Last-Event-ID` cursor so the next SSE reconnect
    /// opens a fresh stream with no resume token.
    func clearSyncState(key: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM sync_state WHERE key = ?",
                arguments: [key]
            )
        }
    }

    // MARK: - Local-id rewriting

    /// Rewrite any queued record whose `local_id` or embedded payload id
    /// references `from` to use `to`. Called after `createItem` replay when
    /// the server-returned id differs from the client-supplied id.
    ///
    /// Under today's UUIDv7 client-owned ID model this never fires, but it
    /// protects against any future server-assigned-id path and makes the
    /// invariant explicit. The `createItem` record itself is the source of
    /// truth for its own local id and is not rewritten.
    ///
    /// Rewrites span: `updateItem`, `deleteItem`, `restoreItem`,
    /// `transitionItem`, `purgeItem`, `setMetadata`, `mergeMetadata`,
    /// `addTags`, `removeTag`, `setExtension`, `deleteExtension`, and the
    /// source/target fields of `createEdge`.
    ///
    /// All updates run in a single write transaction.
    public func rewriteLocalId(from oldId: String, to newId: String) throws {
        guard oldId != newId else { return }
        try pool.write { db in
            // Fetch every row whose local_id matches — item-scoped mutations
            // and the two edge endpoints all key off local_id for direct
            // dependents. We still need to rewrite embedded payload ids
            // field-by-field since the payload JSON holds them redundantly.
            let rows = try PendingMutationRecord
                .filter(Column("local_id") == oldId)
                .fetchAll(db)

            for row in rows {
                // `createItem` is the source of truth for its own local id —
                // leave it untouched. The reconciler only calls us after the
                // createItem has been removed from the queue, so in practice
                // this branch is a belt-and-braces guard.
                if row.kind == .createItem { continue }

                let rewritten = try Self.rewritePayload(row: row, from: oldId, to: newId)
                try db.execute(
                    sql: """
                        UPDATE pending_mutations
                           SET local_id = ?,
                               payload_json = ?
                         WHERE id = ?
                        """,
                    arguments: [newId, rewritten, row.id]
                )
            }

            // Edge rows with target == oldId aren't caught above because the
            // edge's local_id is the edge id, not an endpoint id. Rewrite
            // those by scanning the createEdge rows whose payload references
            // the old id as target (source was already caught above via
            // local_id? No — createEdge's local_id is the edge id. So scan
            // all createEdge rows for either endpoint match).
            let edgeRows = try PendingMutationRecord
                .filter(Column("kind") == PendingMutationRecord.Kind.createEdge.rawValue)
                .fetchAll(db)
            for row in edgeRows {
                let (rewritten, changed) = try Self.rewriteEdgeEndpoints(
                    payloadJson: row.payloadJson, from: oldId, to: newId
                )
                if changed {
                    try db.execute(
                        sql: "UPDATE pending_mutations SET payload_json = ? WHERE id = ?",
                        arguments: [rewritten, row.id]
                    )
                }
            }
        }
    }

    // MARK: - Cascade drop

    /// Remove every queued mutation that references `localId` as its
    /// item-scope target or as an edge endpoint. Called from
    /// ``SyncEngine`` after a permanent `createItem` drop so dependent
    /// mutations (updates, metadata writes, edges spawned from the item)
    /// don't spam 404s one-by-one on subsequent replay cycles.
    ///
    /// Cascade coverage:
    /// - Item-scoped mutations keyed on `local_id`: `updateItem`,
    ///   `deleteItem`, `restoreItem`, `transitionItem`, `purgeItem`,
    ///   `setMetadata`, `mergeMetadata`, `addTags`, `removeTag`,
    ///   `setExtension`, `deleteExtension`.
    /// - `createEdge` rows whose payload source or target matches
    ///   `localId`.
    /// - `updateEdge` / `deleteEdge` rows keyed on an edge id that was
    ///   about to be created by one of the cascade-dropped `createEdge`
    ///   rows. We never ship the edge to the server, so these follow-ups
    ///   are guaranteed orphans.
    ///
    /// The `createItem` record itself is *not* removed by this call —
    /// ``SyncEngine`` removes it first via ``remove(id:)`` so attempt
    /// bookkeeping fires once for the root failure. `rewriteLocalId`'s
    /// sibling comment applies.
    ///
    /// Runs inside a single write transaction. Returns the cascade-deleted
    /// records (excluding the already-removed `createItem` root) so the
    /// caller can emit one ``SyncEvent/mutationDropped`` per orphan.
    // Internal because `PendingMutationRecord` is an internal type — SDK
    // consumers have no reason to reach into the queue directly; this API
    // exists so `SyncEngine` can cascade-drop after a permanent `createItem`
    // failure. Tests import `@testable` and can call it freely.
    @discardableResult
    func dropMutationsReferencingLocalId(_ localId: String) throws -> [PendingMutationRecord] {
        try pool.write { db in
            // Pass 1 — item-scope direct matches (local_id column).
            let directMatches = try PendingMutationRecord
                .filter(Column("local_id") == localId)
                .fetchAll(db)

            // `createItem` is owned by the caller's drop path; leave it for
            // them to remove + emit their own event. Cascading drops for any
            // *other* kind keyed off this local id — e.g. an earlier update
            // queued against the same id — are this method's job.
            let itemScopeDeletes = directMatches.filter { $0.kind != .createItem }

            // Pass 2 — createEdge rows whose payload references localId.
            let allEdgeCreates = try PendingMutationRecord
                .filter(Column("kind") == PendingMutationRecord.Kind.createEdge.rawValue)
                .fetchAll(db)
            var edgeCreateDeletes: [PendingMutationRecord] = []
            var cascadedEdgeIds = Set<String>()
            for row in allEdgeCreates {
                let data = row.payloadJson.data(using: .utf8) ?? Data()
                guard let payload = try? Self.decoder.decode(CreateEdgePayload.self, from: data) else {
                    continue
                }
                if payload.source == localId || payload.target == localId {
                    edgeCreateDeletes.append(row)
                    if let edgeId = row.localId {
                        cascadedEdgeIds.insert(edgeId)
                    }
                }
            }

            // Pass 3 — orphaned updateEdge / deleteEdge follow-ups for any
            // edge id we just cascade-deleted. Those edges never reach the
            // server, so the follow-ups would 404 on replay.
            var edgeFollowUpDeletes: [PendingMutationRecord] = []
            if !cascadedEdgeIds.isEmpty {
                let candidates = try PendingMutationRecord
                    .filter([
                        PendingMutationRecord.Kind.updateEdge.rawValue,
                        PendingMutationRecord.Kind.deleteEdge.rawValue,
                    ].contains(Column("kind")))
                    .fetchAll(db)
                for row in candidates {
                    if let localId = row.localId, cascadedEdgeIds.contains(localId) {
                        edgeFollowUpDeletes.append(row)
                    }
                }
            }

            let allDeletes = itemScopeDeletes + edgeCreateDeletes + edgeFollowUpDeletes
            for row in allDeletes {
                try db.execute(
                    sql: "DELETE FROM pending_mutations WHERE id = ?",
                    arguments: [row.id]
                )
            }
            return allDeletes
        }
    }

    // Rewrite the id fields inside a payload JSON for non-edge item-scoped
    // mutations. Returns the rewritten JSON string.
    private static func rewritePayload(
        row: PendingMutationRecord,
        from oldId: String,
        to newId: String
    ) throws -> String {
        let data = row.payloadJson.data(using: .utf8) ?? Data()
        let encoded: Data
        switch row.kind {
        case .createItem:
            // Left untouched at the call site; encode round-trip for safety.
            return row.payloadJson

        case .updateItem:
            var p = try decoder.decode(UpdateItemPayload.self, from: data)
            if p.id == oldId {
                p = UpdateItemPayload(
                    id: newId,
                    properties: p.properties,
                    version: p.version,
                    conflict: p.conflict,
                    library: p.library
                )
            }
            encoded = try encoder.encode(p)

        case .deleteItem, .restoreItem, .purgeItem, .deleteEdge:
            var p = try decoder.decode(IDPayload.self, from: data)
            if p.id == oldId { p = IDPayload(id: newId) }
            encoded = try encoder.encode(p)

        case .transitionItem:
            var p = try decoder.decode(TransitionPayload.self, from: data)
            if p.id == oldId { p = TransitionPayload(id: newId, state: p.state) }
            encoded = try encoder.encode(p)

        case .createEdge:
            var p = try decoder.decode(CreateEdgePayload.self, from: data)
            let source = p.source == oldId ? newId : p.source
            let target = p.target == oldId ? newId : p.target
            p = CreateEdgePayload(
                source: source, target: target,
                edgeType: p.edgeType, properties: p.properties
            )
            encoded = try encoder.encode(p)

        case .updateEdge:
            var p = try decoder.decode(UpdateEdgePayload.self, from: data)
            if p.id == oldId { p = UpdateEdgePayload(id: newId, properties: p.properties) }
            encoded = try encoder.encode(p)

        case .setMetadata, .mergeMetadata:
            var p = try decoder.decode(MetadataPayload.self, from: data)
            if p.itemId == oldId { p = MetadataPayload(itemId: newId, input: p.input) }
            encoded = try encoder.encode(p)

        case .addTags:
            var p = try decoder.decode(AddTagsPayload.self, from: data)
            if p.itemId == oldId { p = AddTagsPayload(itemId: newId, tags: p.tags) }
            encoded = try encoder.encode(p)

        case .removeTag:
            var p = try decoder.decode(RemoveTagPayload.self, from: data)
            if p.itemId == oldId { p = RemoveTagPayload(itemId: newId, tag: p.tag) }
            encoded = try encoder.encode(p)

        case .setExtension:
            var p = try decoder.decode(SetExtensionPayload.self, from: data)
            if p.itemId == oldId {
                p = SetExtensionPayload(itemId: newId, namespace: p.namespace, data: p.data)
            }
            encoded = try encoder.encode(p)

        case .deleteExtension:
            var p = try decoder.decode(DeleteExtensionPayload.self, from: data)
            if p.itemId == oldId {
                p = DeleteExtensionPayload(itemId: newId, namespace: p.namespace)
            }
            encoded = try encoder.encode(p)
        }

        return String(data: encoded, encoding: .utf8) ?? row.payloadJson
    }

    // Rewrite source/target endpoints inside a createEdge payload. Returns
    // the (possibly unchanged) JSON and a flag indicating whether any change
    // was made.
    private static func rewriteEdgeEndpoints(
        payloadJson: String,
        from oldId: String,
        to newId: String
    ) throws -> (String, Bool) {
        let data = payloadJson.data(using: .utf8) ?? Data()
        let p = try decoder.decode(CreateEdgePayload.self, from: data)
        let newSource = p.source == oldId ? newId : p.source
        let newTarget = p.target == oldId ? newId : p.target
        guard newSource != p.source || newTarget != p.target else {
            return (payloadJson, false)
        }
        let rewritten = CreateEdgePayload(
            source: newSource, target: newTarget,
            edgeType: p.edgeType, properties: p.properties
        )
        let encoded = try encoder.encode(rewritten)
        return (String(data: encoded, encoding: .utf8) ?? payloadJson, true)
    }
}
