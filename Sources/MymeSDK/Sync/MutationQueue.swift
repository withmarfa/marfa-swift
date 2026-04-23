import Foundation
import SwiftData

// MARK: - Pending mutation record (Sendable DTO)

/// Sendable value snapshot of a queued mutation.
///
/// `MutationQueue` translates between this DTO and ``PendingMutationModel``
/// at the actor boundary — `@Model` instances must never cross actors,
/// so every API surface (``fetchAll``, ``rewriteLocalId``,
/// ``dropMutationsReferencingLocalId``) returns these.
public struct PendingMutationRecord: Sendable, Codable, Equatable {
    /// UUIDv4 of this mutation record (the server never sees it).
    public var id: String
    public var kind: MutationKind
    public var payloadJson: String
    public var sourceId: String?
    public var localId: String?
    public var createdAt: String
    public var attemptCount: Int
    public var lastError: String?
    /// ISO 8601 timestamp of the last replay attempt. Nil before the first
    /// attempt or for rows migrated from schema v1 that never retried.
    public var lastAttemptAt: String?

    public init(
        id: String,
        kind: MutationKind,
        payloadJson: String,
        sourceId: String? = nil,
        localId: String? = nil,
        createdAt: String,
        attemptCount: Int = 0,
        lastError: String? = nil,
        lastAttemptAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.payloadJson = payloadJson
        self.sourceId = sourceId
        self.localId = localId
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.lastAttemptAt = lastAttemptAt
    }
}

extension PendingMutationModel {
    /// Snapshots this `@Model` row into a Sendable wire DTO.
    func toRecord() -> PendingMutationRecord {
        PendingMutationRecord(
            id: id,
            kind: kind,
            payloadJson: payloadJson,
            sourceId: sourceId,
            localId: localId,
            createdAt: createdAt,
            attemptCount: attemptCount,
            lastError: lastError,
            lastAttemptAt: lastAttemptAt
        )
    }

    /// Mutates this model in place from a record. Used by re-write paths.
    func apply(_ record: PendingMutationRecord) {
        id = record.id
        kindRaw = record.kind.rawValue
        payloadJson = record.payloadJson
        sourceId = record.sourceId
        localId = record.localId
        createdAt = record.createdAt
        attemptCount = record.attemptCount
        lastError = record.lastError
        lastAttemptAt = record.lastAttemptAt
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

/// Payload for `uploadBlob`.
///
/// The binary data itself is stored in `PendingBlobModel` keyed by
/// `hash` so `payload_json` stays lean. `hash` is the SHA-256 content
/// address (`"sha256:<hex>"`), identical to what the server returns on
/// successful upload — callers can use it immediately after queuing to
/// create items and edges that reference the blob before it reaches
/// the server.
struct UploadBlobPayload: Codable, Sendable {
    let hash: String
    let mimeType: String
    let size: Int
}

/// Payload for `bulk` — `POST /items/bulk` list-in. The whole caller
/// input travels verbatim so replay re-issues the identical call.
struct BulkPayload: Codable, Sendable {
    let input: BulkInput
}

/// Payload for `bulkAction` — `POST /items/bulk_action` filter-in.
/// Same round-trip-exact semantics as `BulkPayload`.
struct BulkActionPayload: Codable, Sendable {
    let input: BulkActionInput
}

// MARK: - MutationQueue actor

/// Durable queue of pending server writes.
///
/// Mutations are appended immediately in the namespace's local-write
/// path and dequeued by ``SyncEngine`` when the client goes online.
/// Idempotency for item creates is enforced via the `sourceId` field:
/// the server returns 409 `duplicate_source` when the (source, sourceId)
/// pair already exists, which the engine treats as a successful no-op.
///
/// `@ModelActor`-isolated. Shares its ``ModelContainer`` with
/// ``LocalStore``; cross-actor saves serialise at the SQLite layer.
@ModelActor
public actor MutationQueue {

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Enqueue event broadcast
    //
    // Each successful enqueue yields once to every active subscriber on the
    // `enqueueEvents` stream. The `SyncEngine` listens to this stream and
    // schedules a debounced proactive drain, closing the gap where writes
    // sat in the queue until an SSE stream happened to close. The continuation
    // set mirrors `ConnectionStateManager.continuations` — UUID-keyed
    // dictionary, hopped into from the nonisolated factory via a `Task`.

    private var enqueueContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Stream that yields once after every successful enqueue (including
    /// `enqueueBlobUpload`). Yields `Void` — subscribers treat it as a
    /// "something happened" pulse and query the queue for detail.
    ///
    /// `nonisolated` so callers subscribe without an actor hop; registration
    /// and any per-continuation cleanup happen inside internal actor-isolated
    /// tasks. Shape matches `ConnectionStateManager.stateUpdates`.
    public nonisolated var enqueueEvents: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.subscribeEnqueue(id: id, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeEnqueueContinuation(id: id)
                }
            }
        }
    }

    private func subscribeEnqueue(
        id: UUID,
        continuation: AsyncStream<Void>.Continuation
    ) {
        enqueueContinuations[id] = continuation
    }

    private func removeEnqueueContinuation(id: UUID) {
        enqueueContinuations.removeValue(forKey: id)
    }

    private func notifyEnqueued() {
        for continuation in enqueueContinuations.values {
            continuation.yield(())
        }
    }

    // MARK: - Enqueue helpers

    private func enqueue(
        kind: MutationKind,
        payload: some Encodable & Sendable,
        sourceId: String? = nil,
        localId: String? = nil
    ) throws {
        let data = try MutationQueue.encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LocalStoreError.encodingFailure("mutation payload")
        }
        // `Date.ISO8601FormatStyle` is `Sendable`; `ISO8601DateFormatter`
        // is not, so creating one here would violate Swift 6 strict
        // concurrency on every enqueue even though it works at runtime.
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let model = PendingMutationModel()
        model.id = UUID().uuidString.lowercased()
        model.kind = kind
        model.payloadJson = json
        model.sourceId = sourceId
        model.localId = localId
        model.createdAt = now
        model.attemptCount = 0
        model.lastError = nil
        model.lastAttemptAt = nil
        modelContext.insert(model)
        try modelContext.save()
        notifyEnqueued()
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

    func enqueueBulk(_ input: BulkInput) throws {
        try enqueue(kind: .bulk, payload: BulkPayload(input: input))
    }

    func enqueueBulkAction(_ input: BulkActionInput) throws {
        try enqueue(kind: .bulkAction, payload: BulkActionPayload(input: input))
    }

    /// Enqueues a blob upload. Inserts the binary data into the
    /// `PendingBlobModel` table (keyed by hash) and records an
    /// `uploadBlob` mutation. Both writes run in a single
    /// `modelContext.save()` so the mutation is never left without its
    /// data — atomicity guarantee from the legacy schema, preserved.
    ///
    /// If a blob row for this hash already exists (same data uploaded
    /// twice while offline), the existing row is preserved and a second
    /// mutation row is still inserted — the second drain will find the
    /// row missing and treat the upload as already complete.
    func enqueueBlobUpload(hash: String, data: Data, mimeType: String) throws {
        let payload = UploadBlobPayload(hash: hash, mimeType: mimeType, size: data.count)
        let payloadData = try MutationQueue.encoder.encode(payload)
        guard let json = String(data: payloadData, encoding: .utf8) else {
            throw LocalStoreError.encodingFailure("uploadBlob payload")
        }
        let now = Date().ISO8601Format(.init(includingFractionalSeconds: true))

        // INSERT-OR-IGNORE equivalent: only insert a fresh blob row if
        // there isn't already one for this hash. A re-enqueue of the
        // same content keeps the existing bytes intact.
        let blobPredicate = #Predicate<PendingBlobModel> { $0.contentHash == hash }
        var blobDescriptor = FetchDescriptor<PendingBlobModel>(predicate: blobPredicate)
        blobDescriptor.fetchLimit = 1
        if try modelContext.fetch(blobDescriptor).first == nil {
            let blob = PendingBlobModel()
            blob.contentHash = hash
            blob.data = data
            blob.mimeType = mimeType
            modelContext.insert(blob)
        }

        let model = PendingMutationModel()
        model.id = UUID().uuidString.lowercased()
        model.kind = .uploadBlob
        model.payloadJson = json
        model.sourceId = nil
        model.localId = nil
        model.createdAt = now
        model.attemptCount = 0
        model.lastError = nil
        model.lastAttemptAt = nil
        modelContext.insert(model)

        // One save commits both rows as a single SQLite transaction.
        try modelContext.save()
        notifyEnqueued()
    }

    // MARK: - Pending blob access

    /// Returns the raw bytes stored for a pending blob upload, or `nil`
    /// if the row has already been deleted (upload succeeded or was
    /// dropped).
    func fetchPendingBlob(hash: String) throws -> Data? {
        let predicate = #Predicate<PendingBlobModel> { $0.contentHash == hash }
        var descriptor = FetchDescriptor<PendingBlobModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.data
    }

    /// Removes a pending blob data row after a successful upload.
    func deletePendingBlob(hash: String) throws {
        let predicate = #Predicate<PendingBlobModel> { $0.contentHash == hash }
        var descriptor = FetchDescriptor<PendingBlobModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(model)
        try modelContext.save()
    }

    // MARK: - Dequeue / drain

    /// Returns all pending mutations in creation order, snapshotted into
    /// Sendable DTOs.
    func fetchAll() throws -> [PendingMutationRecord] {
        let descriptor = FetchDescriptor<PendingMutationModel>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    /// Removes a successfully replayed mutation.
    func remove(id: String) throws {
        let predicate = #Predicate<PendingMutationModel> { $0.id == id }
        var descriptor = FetchDescriptor<PendingMutationModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(model)
        try modelContext.save()
    }

    /// Records a failed replay attempt. Bumps `attemptCount`, stores the
    /// error message, and stamps `lastAttemptAt` with the current time so
    /// consumers can surface "last tried X ago" affordances.
    func recordFailure(id: String, error: String) throws {
        let predicate = #Predicate<PendingMutationModel> { $0.id == id }
        var descriptor = FetchDescriptor<PendingMutationModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        model.attemptCount += 1
        model.lastError = error
        model.lastAttemptAt = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        try modelContext.save()
    }

    /// Returns consumer-facing snapshots for every queued mutation.
    ///
    /// Derives ``PendingMutationStatus`` from persisted columns plus the
    /// `inFlight` set the ``SyncEngine`` provides — queue rows whose id is
    /// in `inFlight` report `.inFlight`; rows with a `lastError` report
    /// `.failed`; everything else reports `.pending`. Order matches
    /// ``fetchAll`` (ascending `createdAt`, the drain order).
    ///
    /// Timestamps that fail to parse fall back to `Date()` rather than
    /// crashing — the queue's writers use a single strategy so parse
    /// failures would indicate disk corruption and shouldn't take the app
    /// down; the UI gets a plausible value instead of a missing row.
    func snapshots(inFlight: Set<String>) throws -> [PendingMutationSnapshot] {
        let descriptor = FetchDescriptor<PendingMutationModel>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let strategy = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try modelContext.fetch(descriptor).map { model in
            let createdAt = (try? Date(model.createdAt, strategy: strategy)) ?? Date()
            let lastAttempt: Date? = model.lastAttemptAt.flatMap {
                try? Date($0, strategy: strategy)
            }
            let status: PendingMutationStatus
            if inFlight.contains(model.id) {
                status = .inFlight
            } else if let err = model.lastError {
                status = .failed(lastError: err, lastAttemptAt: lastAttempt)
            } else {
                status = .pending
            }
            return PendingMutationSnapshot(
                id: model.id,
                kind: model.kind,
                itemId: model.localId,
                createdAt: createdAt,
                attemptCount: model.attemptCount,
                status: status
            )
        }
    }

    /// `true` when the queue is empty.
    var isEmpty: Bool {
        get throws {
            var descriptor = FetchDescriptor<PendingMutationModel>()
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).isEmpty
        }
    }

    // MARK: - Sync state (Last-Event-ID cursor)

    func loadSyncState(key: String) throws -> String? {
        let predicate = #Predicate<SyncStateModel> { $0.key == key }
        var descriptor = FetchDescriptor<SyncStateModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.value
    }

    func saveSyncState(key: String, value: String) throws {
        let predicate = #Predicate<SyncStateModel> { $0.key == key }
        var descriptor = FetchDescriptor<SyncStateModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.value = value
        } else {
            let model = SyncStateModel()
            model.key = key
            model.value = value
            modelContext.insert(model)
        }
        try modelContext.save()
    }

    /// Clears a persisted `sync_state` key. Used by the
    /// `catchup_too_old` handler to reset the `Last-Event-ID` cursor so
    /// the next SSE reconnect opens a fresh stream with no resume token.
    func clearSyncState(key: String) throws {
        let predicate = #Predicate<SyncStateModel> { $0.key == key }
        var descriptor = FetchDescriptor<SyncStateModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(model)
        try modelContext.save()
    }

    // MARK: - Local-id rewriting

    /// Rewrite any queued record whose `localId` or embedded payload id
    /// references `from` to use `to`. Called after `createItem` replay
    /// when the server-returned id differs from the client-supplied id.
    ///
    /// Under today's UUIDv7 client-owned ID model this never fires, but
    /// it protects against any future server-assigned-id path and makes
    /// the invariant explicit. The `createItem` record itself is the
    /// source of truth for its own local id and is not rewritten.
    ///
    /// Rewrites span: `updateItem`, `deleteItem`, `restoreItem`,
    /// `transitionItem`, `purgeItem`, `setMetadata`, `mergeMetadata`,
    /// `addTags`, `removeTag`, `setExtension`, `deleteExtension`, and
    /// the source/target fields of `createEdge`.
    ///
    /// All updates run in a single `modelContext.save()`.
    public func rewriteLocalId(from oldId: String, to newId: String) throws {
        guard oldId != newId else { return }

        // Pass 1 — every row whose `localId` matches.
        let directPredicate = #Predicate<PendingMutationModel> { $0.localId == oldId }
        let directDescriptor = FetchDescriptor<PendingMutationModel>(predicate: directPredicate)
        let direct = try modelContext.fetch(directDescriptor)
        for model in direct {
            // `createItem` is the source of truth for its own local id —
            // leave it untouched. Belt-and-braces: the reconciler only
            // calls us after `createItem` has been removed from the queue.
            if model.kind == .createItem { continue }
            let rewritten = try Self.rewritePayload(record: model.toRecord(), from: oldId, to: newId)
            model.localId = newId
            model.payloadJson = rewritten
        }

        // Pass 2 — createEdge rows whose payload references oldId on
        // the target side. Source-side matches are caught by pass 1
        // since createEdge's localId is the edge id, not an endpoint.
        let createEdgeRaw = MutationKind.createEdge.rawValue
        let edgePredicate = #Predicate<PendingMutationModel> { $0.kindRaw == createEdgeRaw }
        let edgeDescriptor = FetchDescriptor<PendingMutationModel>(predicate: edgePredicate)
        let edges = try modelContext.fetch(edgeDescriptor)
        for model in edges {
            let (rewritten, changed) = try Self.rewriteEdgeEndpoints(
                payloadJson: model.payloadJson, from: oldId, to: newId
            )
            if changed {
                model.payloadJson = rewritten
            }
        }

        try modelContext.save()
    }

    // MARK: - Cascade drop

    /// Remove every queued mutation that references `localId` as its
    /// item-scope target or as an edge endpoint. Called from
    /// ``SyncEngine`` after a permanent `createItem` drop so dependent
    /// mutations (updates, metadata writes, edges spawned from the item)
    /// don't spam 404s one-by-one on subsequent replay cycles.
    ///
    /// Cascade coverage:
    /// - Item-scoped mutations keyed on `localId`: `updateItem`,
    ///   `deleteItem`, `restoreItem`, `transitionItem`, `purgeItem`,
    ///   `setMetadata`, `mergeMetadata`, `addTags`, `removeTag`,
    ///   `setExtension`, `deleteExtension`.
    /// - `createEdge` rows whose payload source or target matches
    ///   `localId`.
    /// - `updateEdge` / `deleteEdge` rows keyed on an edge id that was
    ///   about to be created by one of the cascade-dropped `createEdge`
    ///   rows. We never ship the edge to the server, so these
    ///   follow-ups are guaranteed orphans.
    ///
    /// The `createItem` record itself is *not* removed by this call —
    /// ``SyncEngine`` removes it first via ``remove(id:)`` so attempt
    /// bookkeeping fires once for the root failure.
    ///
    /// All deletes run in a single `modelContext.save()`. Returns the
    /// cascade-deleted records (excluding the already-removed
    /// `createItem` root) so the caller can emit one
    /// ``SyncEvent/mutationDropped`` per orphan.
    @discardableResult
    func dropMutationsReferencingLocalId(_ localId: String) throws -> [PendingMutationRecord] {
        // Pass 1 — item-scope direct matches (`localId` column).
        let directPredicate = #Predicate<PendingMutationModel> { $0.localId == localId }
        let directDescriptor = FetchDescriptor<PendingMutationModel>(predicate: directPredicate)
        let directMatches = try modelContext.fetch(directDescriptor)
        let itemScopeDeletes = directMatches.filter { $0.kind != .createItem }

        // Pass 2 — createEdge rows whose payload references `localId`.
        let createEdgeRaw = MutationKind.createEdge.rawValue
        let edgePredicate = #Predicate<PendingMutationModel> { $0.kindRaw == createEdgeRaw }
        let edgeDescriptor = FetchDescriptor<PendingMutationModel>(predicate: edgePredicate)
        let edgeCreates = try modelContext.fetch(edgeDescriptor)

        var edgeCreateDeletes: [PendingMutationModel] = []
        var cascadedEdgeIds = Set<String>()
        for model in edgeCreates {
            let data = model.payloadJson.data(using: .utf8) ?? Data()
            guard let payload = try? Self.decoder.decode(CreateEdgePayload.self, from: data) else {
                continue
            }
            if payload.source == localId || payload.target == localId {
                edgeCreateDeletes.append(model)
                if let edgeId = model.localId {
                    cascadedEdgeIds.insert(edgeId)
                }
            }
        }

        // Pass 3 — orphaned updateEdge / deleteEdge follow-ups for any
        // edge id we just cascade-deleted. Those edges never reach the
        // server, so the follow-ups would 404 on replay.
        var edgeFollowUpDeletes: [PendingMutationModel] = []
        if !cascadedEdgeIds.isEmpty {
            let updateRaw = MutationKind.updateEdge.rawValue
            let deleteRaw = MutationKind.deleteEdge.rawValue
            let followUpPredicate = #Predicate<PendingMutationModel> { model in
                model.kindRaw == updateRaw || model.kindRaw == deleteRaw
            }
            let followUpDescriptor = FetchDescriptor<PendingMutationModel>(predicate: followUpPredicate)
            let candidates = try modelContext.fetch(followUpDescriptor)
            for model in candidates {
                if let id = model.localId, cascadedEdgeIds.contains(id) {
                    edgeFollowUpDeletes.append(model)
                }
            }
        }

        let allDeletes = itemScopeDeletes + edgeCreateDeletes + edgeFollowUpDeletes
        let snapshot = allDeletes.map { $0.toRecord() }
        for model in allDeletes {
            modelContext.delete(model)
        }
        try modelContext.save()
        return snapshot
    }

    // Rewrite the id fields inside a payload JSON for non-edge
    // item-scoped mutations. Returns the rewritten JSON string.
    private static func rewritePayload(
        record: PendingMutationRecord,
        from oldId: String,
        to newId: String
    ) throws -> String {
        let data = record.payloadJson.data(using: .utf8) ?? Data()
        let encoded: Data
        switch record.kind {
        case .createItem:
            // Left untouched at the call site; encode round-trip for safety.
            return record.payloadJson

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

        case .uploadBlob:
            // Blob uploads carry a content hash, not an item ID —
            // nothing to rewrite when a createItem's local ID changes.
            return record.payloadJson

        case .bulk, .bulkAction:
            // Bulk payloads don't reference specific in-flight local IDs:
            // `bulk` items are keyed by `(source, source_id)`; `bulkAction`
            // resolves matches via a filter at replay time. Nothing to
            // rewrite if a createItem's local ID changes.
            return record.payloadJson
        }

        return String(data: encoded, encoding: .utf8) ?? record.payloadJson
    }

    // Rewrite source/target endpoints inside a createEdge payload.
    // Returns the (possibly unchanged) JSON and a flag indicating
    // whether any change was made.
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
