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
    /// The most recent failure message, with any block-reason prefix already
    /// removed — see ``blockedReason``.
    public var lastError: String?
    public var state: PendingMutationState

    /// Why this row is blocked, or `nil` when it is not. Parsed out of the
    /// stored `lastError` at the actor boundary so no consumer meets the
    /// encoding.
    public var blockedReason: PendingMutationBlockReason?

    public init(
        id: String,
        kind: MutationKind,
        payloadJson: String,
        sourceId: String? = nil,
        localId: String? = nil,
        createdAt: String,
        attemptCount: Int = 0,
        lastError: String? = nil,
        state: PendingMutationState = .pending,
        blockedReason: PendingMutationBlockReason? = nil
    ) {
        self.id = id
        self.kind = kind
        self.payloadJson = payloadJson
        self.sourceId = sourceId
        self.localId = localId
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.state = state
        self.blockedReason = blockedReason
    }
}

extension PendingMutationModel {
    /// Snapshots this `@Model` row into a Sendable wire DTO.
    /// The block reason and the human-readable message, split out of the single
    /// stored column. The one place either is decoded — ``toRecord()`` and
    /// ``MutationQueue/clearBlock(id:)`` both read it here rather than parsing
    /// the column themselves.
    var decodedError: (reason: PendingMutationBlockReason?, message: String?) {
        BlockedErrorEncoding.decode(lastError)
    }

    func toRecord() -> PendingMutationRecord {
        let decoded = decodedError
        return PendingMutationRecord(
            id: id,
            kind: kind,
            payloadJson: payloadJson,
            sourceId: sourceId,
            localId: localId,
            createdAt: createdAt,
            attemptCount: attemptCount,
            lastError: decoded.message,
            state: state,
            blockedReason: state == .blocked ? (decoded.reason ?? .retriesExhausted) : nil
        )
    }
}

// MARK: - Dropped mutation record (Sendable DTO)

/// Sendable value snapshot of a dropped mutation row.
///
/// ``MutationQueue`` translates between this DTO and
/// ``DroppedMutationModel`` at the actor boundary — `@Model`
/// instances must never cross actors, so ``MutationQueue/fetchDropped``
/// returns these.
public struct DroppedMutationRecord: Sendable, Codable, Equatable, Identifiable {
    /// UUIDv4 — preserved from the original ``PendingMutationRecord/id``
    /// of the live row that was dropped.
    public var id: String
    public var kind: MutationKind
    public var payloadJson: String
    public var localId: String?
    /// ISO 8601 with fractional seconds — original
    /// ``PendingMutationRecord/createdAt`` from the live row.
    public var enqueuedAt: String
    /// ISO 8601 with fractional seconds — when the engine observed
    /// the permanent error.
    public var droppedAt: String
    public var attemptCount: Int
    /// HTTP status from the dropping error (typically 400/403/404);
    /// `0` for non-HTTP permanent failures.
    public var errorStatus: Int
    /// ``MarfaError/code`` — e.g. `"validation_error"`, `"not_found"`.
    public var errorCode: String
    /// ``MarfaError/message`` — capped at 1024 characters at write time.
    public var errorMessage: String
    /// JSON-encoded ``MarfaError/details``, or `nil` when the server
    /// response carried no `details` payload.
    public var errorDetailsJson: String?

    public init(
        id: String,
        kind: MutationKind,
        payloadJson: String,
        localId: String?,
        enqueuedAt: String,
        droppedAt: String,
        attemptCount: Int,
        errorStatus: Int,
        errorCode: String,
        errorMessage: String,
        errorDetailsJson: String?
    ) {
        self.id = id
        self.kind = kind
        self.payloadJson = payloadJson
        self.localId = localId
        self.enqueuedAt = enqueuedAt
        self.droppedAt = droppedAt
        self.attemptCount = attemptCount
        self.errorStatus = errorStatus
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.errorDetailsJson = errorDetailsJson
    }
}

extension DroppedMutationModel {
    /// Snapshots this `@Model` row into a Sendable wire DTO.
    func toRecord() -> DroppedMutationRecord {
        DroppedMutationRecord(
            id: id,
            kind: kind,
            payloadJson: payloadJson,
            localId: localId,
            enqueuedAt: enqueuedAt,
            droppedAt: droppedAt,
            attemptCount: attemptCount,
            errorStatus: errorStatus,
            errorCode: errorCode,
            errorMessage: errorMessage,
            errorDetailsJson: errorDetailsJson
        )
    }
}

// MARK: - Typed payloads

struct CreateItemPayload: Codable, Sendable {
    let input: CreateItemInput
}

/// Payload stored for an `updateItem` mutation.
///
/// `version` and `conflict` capture the per-call conflict context so a
/// replay can apply the same strategy the caller chose. The `.callback`
/// resolver closure is not serializable — on replay, `.callback` degrades
/// to `.auto`. `tier` mirrors the server's separate tier-axis flip on
/// `PATCH /items/:id`.
struct UpdateItemPayload: Codable, Sendable {
    let id: String
    let properties: [String: JSONValue]
    var version: Int?
    var conflict: ConflictStrategy?
    var tier: Tier?
    /// Rename the natural key under this item's `source`. Travels through
    /// replay; the server still enforces `(source, source_id)` uniqueness
    /// at replay time.
    var sourceId: String?
}

struct IDPayload: Codable, Sendable {
    let id: String
}

struct TransitionPayload: Codable, Sendable {
    let id: String
    let state: ItemState
}

struct CreateEdgePayload: Codable, Sendable {
    let source: String
    let target: String
    let edgeType: String
    let properties: [String: JSONValue]?
}

struct UpdateEdgePayload: Codable, Sendable {
    let id: String
    let properties: [String: JSONValue]
}

struct MetadataPayload: Codable, Sendable {
    let itemId: String
    let input: MetadataInput
}

struct AddTagsPayload: Codable, Sendable {
    let itemId: String
    let tags: [String]
}

struct RemoveTagPayload: Codable, Sendable {
    let itemId: String
    let tag: String
}

struct SetExtensionPayload: Codable, Sendable {
    let itemId: String
    let namespace: String
    let data: [String: JSONValue]
}

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

/// The whole input travels verbatim so replay re-issues the identical call.
struct BulkPayload: Codable, Sendable {
    let input: BulkInput
}

struct BulkActionPayload: Codable, Sendable {
    let input: BulkActionInput
}

struct BulkEdgesPayload: Codable, Sendable {
    let input: BulkEdgeInput
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
/// ``LocalStore``; cross-actor saves serialize at the SQLite layer.
@ModelActor
public actor MutationQueue {

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    // MARK: - Drain-request broadcast

    /// Active subscribers to ``drainRequests``. Continuations are appended
    /// on `subscribe` and pruned on the first `.terminated` yield. Pattern
    /// mirrors ``SyncEngine/events``.
    private var drainContinuations: [AsyncStream<Void>.Continuation] = []

    /// A broadcast stream of "a mutation was just enqueued" pings.
    /// ``SyncEngine`` consumes this to trigger a proactive drain against
    /// a live connection — without it, writes made while the engine is
    /// parked on `.online` wait for the next SSE reconnect before the
    /// queue is touched.
    ///
    /// Yields `()` once per successful enqueue (after the SQLite
    /// transaction has committed). Late subscribers do not see past
    /// pings. Multiple subscribers each receive their own continuation.
    ///
    /// Implemented as an `async` computed property so the continuation
    /// registration completes before the caller receives the stream —
    /// a plain `nonisolated var` would schedule the subscribe in a
    /// detached `Task` that races against the first enqueue.
    public var drainRequests: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        drainContinuations.append(continuation)
        return stream
    }

    /// Yield to every active subscriber. Drops finished continuations.
    /// Safe to call from any enqueue path — called after the commit
    /// critical section so subscribers wake to a fully-visible row.
    private func emitDrainRequest() {
        drainContinuations.removeAll { c in
            switch c.yield(()) {
            case .terminated: return true
            default: return false
            }
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
        modelContext.insert(model)
        try modelContext.save()
        emitDrainRequest()
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
        tier: Tier? = nil,
        sourceId: String? = nil
    ) throws {
        try enqueue(
            kind: .updateItem,
            payload: UpdateItemPayload(
                id: id,
                properties: properties,
                version: version,
                conflict: conflict,
                tier: tier,
                sourceId: sourceId
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

    func enqueueTransitionItem(id: String, to state: ItemState) throws {
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

    func enqueueBulkEdges(_ input: BulkEdgeInput) throws {
        try enqueue(kind: .bulkEdges, payload: BulkEdgesPayload(input: input))
    }

    /// Enqueues a blob upload. Inserts the binary data into the
    /// `PendingBlobModel` table (keyed by hash) and records an
    /// `uploadBlob` mutation. Both writes run in a single
    /// `modelContext.save()` so the mutation is never left without its
    /// data — both writes share a single `modelContext.save()` for atomicity.
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
        modelContext.insert(model)

        // One save commits both rows as a single SQLite transaction.
        try modelContext.save()
        emitDrainRequest()
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

    func fetchAll() throws -> [PendingMutationRecord] {
        let descriptor = FetchDescriptor<PendingMutationModel>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    func remove(id: String) throws {
        let predicate = #Predicate<PendingMutationModel> { $0.id == id }
        var descriptor = FetchDescriptor<PendingMutationModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(model)
        try modelContext.save()
    }

    /// Records a failed replay attempt. Also resets `state` to `.pending`
    /// so a `.inFlight` row doesn't appear stuck in the consumer-facing
    /// observable after a transient failure.
    func recordFailure(id: String, error: String) throws {
        let predicate = #Predicate<PendingMutationModel> { $0.id == id }
        var descriptor = FetchDescriptor<PendingMutationModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        model.attemptCount += 1
        model.lastError = error
        model.state = .pending
        try modelContext.save()
    }

    /// Records a failure that no retry can clear. Increments `attemptCount`
    /// like ``recordFailure(id:error:)`` so the count still says how many
    /// attempts it took, stamps the reason into the message, and parks the row
    /// in `.blocked` where the drain will skip it.
    func recordBlocked(
        id: String,
        reason: PendingMutationBlockReason,
        error: String
    ) throws {
        let predicate = #Predicate<PendingMutationModel> { $0.id == id }
        var descriptor = FetchDescriptor<PendingMutationModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        model.attemptCount += 1
        model.lastError = BlockedErrorEncoding.encode(reason: reason, message: error)
        model.state = .blocked
        try modelContext.save()
    }

    /// Returns a blocked row to the queue: the block goes, the attempt count
    /// starts again, and the message keeps its text without the reason prefix
    /// so a consumer can still read what went wrong last time.
    ///
    /// Emits a drain request, as every other write to this queue does. A
    /// `retry` that only changed a column would sit untouched until something
    /// unrelated happened to wake the engine, which is not what the name says.
    ///
    /// **On a row that is not blocked, only the attempt count is reset.** The
    /// state and the message are left exactly as they are, because the row the
    /// caller is most likely to hit by accident is one the engine is replaying
    /// right now: writing `.pending` over `.inFlight` would announce through
    /// ``PendingMutationsQuery`` that a request in flight is not, and rewriting
    /// the message would discard the failure a consumer is displaying. Resetting
    /// the count is the part that means "try this again as if it were new", and
    /// it is safe whatever the row is doing.
    func clearBlock(id: String) throws {
        let predicate = #Predicate<PendingMutationModel> { $0.id == id }
        var descriptor = FetchDescriptor<PendingMutationModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        if model.state == .blocked {
            model.lastError = model.decodedError.message
            model.state = .pending
        }
        model.attemptCount = 0
        try modelContext.save()
        emitDrainRequest()
    }

    /// Flips a pending record's `state` to `.inFlight` immediately
    /// before the sync engine issues its transport call. The transition
    /// is a standalone save so the change is visible to any
    /// `PendingMutationsQuery` subscriber that's observing
    /// `ModelContext.didSave`. Successful replay removes the row
    /// entirely; transient failure reverts to `.pending` via
    /// ``recordFailure(id:error:)``.
    func markInFlight(id: String) throws {
        let predicate = #Predicate<PendingMutationModel> { $0.id == id }
        var descriptor = FetchDescriptor<PendingMutationModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        model.state = .inFlight
        try modelContext.save()
    }

    /// `true` when the queue is empty.
    var isEmpty: Bool {
        get throws {
            var descriptor = FetchDescriptor<PendingMutationModel>()
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).isEmpty
        }
    }

    /// How many writes are queued.
    ///
    /// Distinct from ``isEmpty`` because a refusal is more useful when it says
    /// how much is outstanding: a count that does not fall across retries is a
    /// stuck queue rather than a busy one, and a person needs to tell those
    /// apart. `isEmpty` stays as it is — it stops after one row and is the
    /// cheaper answer where only presence matters.
    var pendingCount: Int {
        get throws {
            try modelContext.fetchCount(FetchDescriptor<PendingMutationModel>())
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
            //
            // `createEdge` is not skipped, and its `localId` is no longer
            // only a local handle: the replay sends that column as the
            // edge's id on the wire, so rewriting it here would rename the
            // row on the server too. Nothing reaches this with an edge id —
            // the column holds an edge's UUIDv7 and `oldId` is an item's,
            // and the only caller is the `createItem` reconcile — but the
            // column is load-bearing now and a future caller should know it.
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
    /// ``SyncEngine`` removes it first via ``recordDropped(record:droppedAt:error:)``
    /// so attempt bookkeeping (and dropped-row persistence) fires once
    /// for the root failure.
    ///
    /// Persistence: every orphan is also captured as a
    /// ``DroppedMutationModel`` row before deletion, so the cascade
    /// surfaces in ``DroppedMutationsQuery`` alongside the root drop.
    /// All inserts and deletes run in a single
    /// `modelContext.save()`. Returns the cascade-deleted records
    /// (excluding the already-removed `createItem` root) so the
    /// caller can emit one ``SyncEvent/mutationDropped`` per orphan.
    @discardableResult
    func dropMutationsReferencingLocalId(
        _ localId: String,
        droppedAt: Date,
        error: MarfaError
    ) throws -> [PendingMutationRecord] {
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
        let droppedAtStr = Self.iso8601(droppedAt)
        for model in allDeletes {
            insertDroppedRow(
                from: model.toRecord(),
                droppedAt: droppedAtStr,
                error: error
            )
            modelContext.delete(model)
        }
        try modelContext.save()
        return snapshot
    }

    // MARK: - Dropped mutation log

    /// Records a permanent drop atomically: inserts a
    /// ``DroppedMutationModel`` row carrying the live record's payload
    /// and the dropping ``MarfaError``, then removes the live
    /// ``PendingMutationModel`` by id, all in one
    /// `modelContext.save()`.
    ///
    /// Called from ``SyncEngine`` at the two permanent-error sites
    /// (root and any direct caller; cascade orphans go through
    /// ``dropMutationsReferencingLocalId(_:droppedAt:error:)``). Apps
    /// observe the persisted rows via ``DroppedMutationsQuery``.
    func recordDropped(
        record: PendingMutationRecord,
        droppedAt: Date,
        error: MarfaError
    ) throws {
        let droppedAtStr = Self.iso8601(droppedAt)
        insertDroppedRow(from: record, droppedAt: droppedAtStr, error: error)

        // Remove the live row, if it's still present. The cascade
        // path can race here when SyncEngine calls `recordDropped`
        // after `dropMutationsReferencingLocalId` has already cleared
        // the row; tolerating the missing row keeps both call sites
        // simple.
        let liveId = record.id
        let predicate = #Predicate<PendingMutationModel> { $0.id == liveId }
        var descriptor = FetchDescriptor<PendingMutationModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let live = try modelContext.fetch(descriptor).first {
            modelContext.delete(live)
        }
        try modelContext.save()
    }

    public func fetchDropped() throws -> [DroppedMutationRecord] {
        let descriptor = FetchDescriptor<DroppedMutationModel>(
            sortBy: [SortDescriptor(\.droppedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    public func dismissDropped(id: String) throws {
        let predicate = #Predicate<DroppedMutationModel> { $0.id == id }
        var descriptor = FetchDescriptor<DroppedMutationModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(model)
        try modelContext.save()
    }

    /// Removes every dropped mutation row whose ``droppedAt``
    /// timestamp is **strictly** earlier than `cutoff`. Rows whose
    /// `droppedAt` exactly matches the cutoff are preserved.
    ///
    /// Comparison runs against the persisted ISO 8601 string with
    /// fractional seconds — fixed-width segments under
    /// ``Date/ISO8601FormatStyle`` give correct lexicographic
    /// ordering for the comparison.
    public func dismissDroppedOlderThan(_ cutoff: Date) throws {
        let cutoffStr = Self.iso8601(cutoff)
        let predicate = #Predicate<DroppedMutationModel> { $0.droppedAt < cutoffStr }
        let descriptor = FetchDescriptor<DroppedMutationModel>(predicate: predicate)
        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else { return }
        for row in rows { modelContext.delete(row) }
        try modelContext.save()
    }

    public func dismissAllDropped() throws {
        let descriptor = FetchDescriptor<DroppedMutationModel>()
        let rows = try modelContext.fetch(descriptor)
        guard !rows.isEmpty else { return }
        for row in rows { modelContext.delete(row) }
        try modelContext.save()
    }

    /// Inserts a single ``DroppedMutationModel`` from a Sendable
    /// record snapshot and a dropping ``MarfaError``. Caller is
    /// responsible for the `modelContext.save()` so multiple inserts
    /// can batch into a single SQLite transaction.
    private func insertDroppedRow(
        from record: PendingMutationRecord,
        droppedAt: String,
        error: MarfaError
    ) {
        let model = DroppedMutationModel()
        model.id = record.id
        model.kindRaw = record.kind.rawValue
        model.payloadJson = record.payloadJson
        model.localId = record.localId
        model.enqueuedAt = record.createdAt
        model.droppedAt = droppedAt
        model.attemptCount = record.attemptCount + 1
        model.errorStatus = error.status
        model.errorCode = error.code
        // Cap the message at 1KB so a pathological server response
        // can't blow up CloudKit row sizes.
        model.errorMessage = String(error.message.prefix(1024))
        if let details = error.details,
           let data = try? Self.encoder.encode(details),
           let json = String(data: data, encoding: .utf8) {
            model.errorDetailsJson = json
        } else {
            model.errorDetailsJson = nil
        }
        modelContext.insert(model)
    }

    private static func iso8601(_ date: Date) -> String {
        date.ISO8601Format(.init(includingFractionalSeconds: true))
    }

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
                    tier: p.tier,
                    sourceId: p.sourceId
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

        case .bulk, .bulkAction, .bulkEdges:
            // Unreachable rather than merely unnecessary, and the reason is
            // the queue's shape rather than anything about the payloads.
            // None of the three enqueue a `localId`, and the rewrite loop
            // fetches on exactly that column, so a bulk record is never
            // handed to this function. The one caller is the `createItem`
            // reconcile, which fires only when the server names a row
            // something other than the id the device sent — and no door
            // does that any more, on any of these paths.
            //
            // Worth stating because the obvious reading is now wrong: bulk
            // items are no longer keyed only by `(source, source_id)`, since
            // a synced page carries the primary id of every row the store
            // wrote. If a future caller ever reaches here with one, these
            // ids are the rows' own names on both sides and rewriting one
            // would rename it on the server too.
            return record.payloadJson
        }

        return String(data: encoded, encoding: .utf8) ?? record.payloadJson
    }

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
