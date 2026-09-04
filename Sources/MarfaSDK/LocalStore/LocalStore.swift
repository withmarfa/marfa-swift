import Foundation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift` for
// the full ruleset. Every predicate in this file compares against stored
// String / Int / Double / Bool columns — never against computed Codable
// enum properties (`state`) and never reaches inside the JSON
// blobs (`propertiesData`, `tagsData`, `extensionsData`).

/// Persistent local mirror of the Marfa data model backed by SwiftData.
///
/// Used in two modes:
/// - **Pure-local** — `MarfaClient.local(path:)`. No server; all namespace
///   calls resolve against this store. Ideal for on-device-only apps,
///   tests, and offline-first prototyping.
/// - **Synced** — `MarfaClient.synced(url:apiKey:storePath:)`. Writes go
///   to the store immediately, then queue to replay against the server.
///   Reads are served locally; the sync engine keeps the store fresh via
///   SSE.
///
/// `@ModelActor` synthesizes:
///   - `init(modelContainer: ModelContainer)`
///   - `nonisolated let modelContainer: ModelContainer`
///   - `nonisolated let modelExecutor: any ModelExecutor`
///   - actor-isolated `modelContext: ModelContext`
///
/// `LocalStore` and ``MutationQueue`` share a single ``ModelContainer`` —
/// each holds its own `ModelContext`, so cross-actor saves serialize at
/// the SQLite layer underneath.
///
/// `@Model` instances must never cross actor boundaries; every method
/// returns wire types (`Item`, `Edge`, `Metadata`) constructed via the
/// mappers in `Schema/V1/Mappers.swift`.
@ModelActor
public actor LocalStore {

    // MARK: - Helpers

    /// ISO 8601 timestamp with fractional seconds, matching the wire
    /// format used by the server. `Date.ISO8601FormatStyle` is a
    /// `Sendable` value type and therefore safe under Swift 6 strict
    /// concurrency, unlike `ISO8601DateFormatter`.
    private static func iso8601(_ date: Date) -> String {
        date.ISO8601Format(.init(includingFractionalSeconds: true))
    }

    private func now() -> String {
        LocalStore.iso8601(Date())
    }

    /// Generates a fresh ID for a new item / edge / record.
    ///
    /// Uses **UUIDv7** — Marfa's canonical ID format. Timestamp-prefixed
    /// and globally unique, so client-generated IDs round-trip cleanly
    /// to the server with no reconciliation race.
    private func newId() -> String {
        UUIDv7.generateString()
    }

    // MARK: - Item CRUD

    /// Creates an item from the given input. Assigns a new UUIDv7 if the
    /// caller didn't supply one — passing `input.id` explicitly is fully
    /// supported and remains the right choice for callers that need to
    /// reference the new id before `createItem` returns.
    ///
    /// In synced mode callers go through `ItemsNamespace.create`, which
    /// stamps a UUIDv7 into `input.id` before calling in, so the queued
    /// mutation payload carries the same id as the stored row.
    func createItem(_ input: CreateItemInput) throws -> Item {
        let now = now()
        let id = input.id ?? newId()
        let item = Item(
            captureLatitude: input.captureLatitude,
            captureLongitude: input.captureLongitude,
            createdAt: input.timestamp ?? now,
            device: input.device,
            edges: nil,
            id: id,
            properties: input.properties,
            schemaVersion: 1,
            source: input.source ?? "local",
            sourceId: input.sourceId,
            state: input.state ?? .active,
            tier: input.tier ?? .library,
            timestamp: input.timestamp ?? now,
            type: input.type,
            updatedAt: now,
            version: 1
        )
        let model = MarfaItemModel.make(from: item)
        modelContext.insert(model)
        try modelContext.save()
        return item
    }

    /// Fetches a single item by ID. Throws ``NotFoundError`` if absent.
    func fetchItem(id: String) throws -> Item {
        let predicate = #Predicate<MarfaItemModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw NotFoundError(message: "Item not found: \(id)")
        }
        return model.toWireItem()
    }

    /// Fetches items, applying optional filters.
    ///
    /// Paginates when the caller sets `limit`: the page carries `hasMore`,
    /// and a cursor to resume from when there is more. This used to apply the
    /// limit and report `hasMore: false` regardless, which reads to a caller
    /// as "that was all of them" and silently truncated every loop that
    /// believed it.
    func fetchItems(filters: ListFilters?) throws -> PaginatedResult<Item> {
        let page = try Self.itemModels(in: modelContext, for: filters)
        return PaginatedResult(
            data: page.rows.map { $0.toWireItem() },
            cursor: page.hasMore ? LocalCursor(o: page.offset + page.rows.count).encoded() : nil,
            hasMore: page.hasMore
        )
    }

    /// The item models a set of filters selects, windowed.
    ///
    /// Two paths, because `tags` cannot narrow a fetch. Tags live in
    /// `MarfaMetadataModel.tagsData`, a blob the predicate engine cannot see
    /// into, so a tag filter can only be applied after a metadata join. That
    /// rules out pushing the limit into the descriptor as well: a page of
    /// `limit` rows that then loses most of itself to the tag filter would
    /// hand back a short page and call it a complete one.
    ///
    /// So a tag-filtered list walks its candidate set and windows here, which
    /// costs a full ordered fetch of everything the other filters allow.
    /// `LocalStoreSearch` makes the same trade for the same reason. Without
    /// tags, nothing changes: the descriptor windows, which is the cheap path
    /// and the common one.
    /// `nonisolated` and context-taking so the reactive queries, which own
    /// their own `ModelContext` and cannot reach the actor, select rows the
    /// same way rather than growing a second copy of this that drifts.
    nonisolated static func itemModels(
        in modelContext: ModelContext,
        for filters: ListFilters?
    ) throws -> (rows: [MarfaItemModel], hasMore: Bool, offset: Int) {
        let offset = try LocalCursor.validated(filters?.cursor) ?? 0
        let required = Set(filters?.tags ?? [])
        // Dates join tags on the slow path for the same reason: the exact
        // answer is only known after the fetch, so the window cannot be
        // pushed into the descriptor without reporting a short page as a
        // whole one.
        let datesNeedSettling = filters?.since != nil || filters?.until != nil

        guard !required.isEmpty || datesNeedSettling else {
            // One row past the limit, so truncation is known without a second
            // count query. The extra row is dropped before the caller sees it.
            var probe = filters
            if let limit = filters?.limit { probe?.limit = limit + 1 }
            let models = try modelContext.fetch(Self.makeItemsDescriptor(filters: probe))
            let page = Self.page(models, limit: filters?.limit)
            return (page.rows, page.hasMore, offset)
        }

        var unwindowed = filters
        unwindowed?.limit = nil
        unwindowed?.cursor = nil
        var candidates = try modelContext.fetch(Self.makeItemsDescriptor(filters: unwindowed))
        candidates = Self.applyDateBounds(candidates, filters: filters)
        if !required.isEmpty {
            candidates = try filterByTags(in: modelContext, candidates, required: required)
        }
        let page = Self.page(Array(candidates.dropFirst(offset)), limit: filters?.limit)
        return (page.rows, page.hasMore, offset)
    }

    /// Settles the rows the descriptor let through permissively.
    ///
    /// Only rows with no timestamp are in question: the descriptor already
    /// compared every other row against the bounds. Those few are judged on
    /// `createdAt`, which is what the server's `COALESCE(timestamp,
    /// created_at)` falls back to.
    nonisolated static func applyDateBounds(
        _ models: [MarfaItemModel],
        filters: ListFilters?
    ) -> [MarfaItemModel] {
        guard filters?.since != nil || filters?.until != nil else { return models }
        return models.filter { item in
            guard item.timestamp.isEmpty else { return true }
            if let since = filters?.since, item.createdAt < since { return false }
            if let until = filters?.until, item.createdAt > until { return false }
            return true
        }
    }

    /// Keeps only the models carrying every requested tag. AND semantics,
    /// matching the server: an item must have all of them, not any.
    nonisolated static func filterByTags(
        in modelContext: ModelContext,
        _ models: [MarfaItemModel],
        required: Set<String>
    ) throws -> [MarfaItemModel] {
        let ids = Set(models.map(\.id))
        guard !ids.isEmpty else { return [] }
        let metaPredicate = #Predicate<MarfaMetadataModel> { ids.contains($0.itemId) }
        let metaModels = try modelContext.fetch(FetchDescriptor(predicate: metaPredicate))
        // First row wins on a duplicate `itemId`, for the reason spelled out
        // in `joinMetadata`: the model carries no `#Unique`, so duplicates are
        // constructible, and the two places that read metadata have to agree
        // on which one they mean.
        let tagsById = Dictionary(
            metaModels.map { ($0.itemId, Set($0.tags)) },
            uniquingKeysWith: { first, _ in first }
        )
        return models.filter { required.isSubset(of: tagsById[$0.id] ?? []) }
    }

    /// Splits an over-fetched result into the page the caller asked for and
    /// whether anything was left behind. The probe asks for `limit + 1`, so a
    /// whole extra row is the signal; it never reaches the caller.
    nonisolated private static func page<M>(_ models: [M], limit: Int?) -> (rows: [M], hasMore: Bool) {
        guard let limit, models.count > limit else { return (models, false) }
        return (Array(models.prefix(limit)), true)
    }

    /// Edges always order by `createdAt` ascending with an `id` tiebreak, so
    /// one helper mints every edge page and its cursor.
    nonisolated private static func edgePage(
        _ models: [MarfaEdgeModel],
        limit: Int?,
        offset: Int
    ) -> PaginatedResult<Edge> {
        let page = Self.page(models, limit: limit)
        return PaginatedResult(
            data: page.rows.map { $0.toWireEdge() },
            cursor: page.hasMore ? LocalCursor(o: offset + page.rows.count).encoded() : nil,
            hasMore: page.hasMore
        )
    }

    /// Fetches items paired with their metadata in two predicate-safe
    /// reads (one over items, one over metadata). Items with no metadata
    /// row fall back to an empty ``Metadata``, matching the
    /// ``fetchMetadata(itemId:)`` contract.
    func fetchItemsWithMetadata(filters: ListFilters?) throws -> [ItemWithMetadata] {
        return try joinMetadata(Self.itemModels(in: modelContext, for: filters).rows)
    }

    /// The paginated form, for callers that page rather than take everything.
    /// Shares the join below, so the two cannot drift on how metadata is
    /// matched or how duplicate rows are resolved.
    func fetchItemsWithMetadataPage(
        filters: ListFilters?
    ) throws -> PaginatedResult<ItemWithMetadata> {
        let page = try Self.itemModels(in: modelContext, for: filters)
        return PaginatedResult(
            data: try joinMetadata(page.rows),
            cursor: page.hasMore ? LocalCursor(o: page.offset + page.rows.count).encoded() : nil,
            hasMore: page.hasMore
        )
    }

    /// Pairs already-ordered item models with their metadata in one further
    /// read. The order of `itemModels` is the order out: the caller sorted
    /// them and a metadata join is not the place to lose that.
    private func joinMetadata(_ itemModels: [MarfaItemModel]) throws -> [ItemWithMetadata] {
        let ids = Set(itemModels.map(\.id))
        guard !ids.isEmpty else { return [] }

        let metaPredicate = #Predicate<MarfaMetadataModel> { ids.contains($0.itemId) }
        let metaDescriptor = FetchDescriptor<MarfaMetadataModel>(predicate: metaPredicate)
        let metaModels = try modelContext.fetch(metaDescriptor)
        // Duplicate `itemId` rows are constructible: the model is indexed on
        // it but carries no `#Unique`, which CloudKit mirroring forbids, and
        // two devices setting metadata on the same item leave two rows.
        // `uniqueKeysWithValues` would trap.
        // Resolved to the FIRST row, not the newest, because `fetchMetadata`
        // and `writeMetadata` both take `.first` under a `fetchLimit` of 1.
        // Picking differently here would not crash — it would render one row
        // in a list and a different one in the detail view of the same item,
        // permanently, since nothing deduplicates. Fetch order is also not
        // recency: no descriptor here sorts, so "newest" would be a guess.
        let metadataById = Dictionary(
            metaModels.map { ($0.itemId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return itemModels.map { model in
            let item = model.toWireItem()
            let metadata = metadataById[model.id]?.toWireMetadata()
                ?? Metadata(extensions: [:], itemId: model.id, tags: [])
            return ItemWithMetadata(item: item, metadata: metadata)
        }
    }

    /// Updates an item with **partial-merge semantics for properties**,
    /// mirroring the server's `PATCH /items/:id` behavior. Caller passes
    /// only the fields it wants to change; existing keys not in the delta
    /// are preserved. `tier` is an optional dimension flag — if provided,
    /// it overrides the existing value; otherwise the existing value is
    /// preserved.
    @discardableResult
    func updateItem(
        id: String,
        properties: [String: JSONValue],
        tier: Tier? = nil
    ) throws -> Item {
        let predicate = #Predicate<MarfaItemModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw NotFoundError(message: "Item not found: \(id)")
        }
        // Merge the delta into the existing properties dict. New keys win
        // on collision; unmentioned keys survive untouched. Parity with
        // the server's PATCH semantics.
        var merged = model.properties
        for (key, value) in properties {
            merged[key] = value
        }
        model.properties = merged
        if let tier {
            model.tier = tier
        }
        model.version += 1
        model.updatedAt = now()
        try modelContext.save()
        return model.toWireItem()
    }

    /// Sets the item's state to `trashed` (soft delete).
    func trashItem(id: String) throws {
        let predicate = #Predicate<MarfaItemModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw NotFoundError(message: "Item not found: \(id)")
        }
        model.state = .trashed
        model.updatedAt = now()
        try modelContext.save()
    }

    /// Sets the item's state to `active` (restores from trash).
    func restoreItem(id: String) throws -> Item {
        let predicate = #Predicate<MarfaItemModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw NotFoundError(message: "Item not found: \(id)")
        }
        model.state = .active
        model.updatedAt = now()
        try modelContext.save()
        return model.toWireItem()
    }

    /// Transitions the item to a new lifecycle state.
    func transitionItem(id: String, to state: ItemState) throws -> Item {
        let predicate = #Predicate<MarfaItemModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw NotFoundError(message: "Item not found: \(id)")
        }
        model.state = state
        model.updatedAt = now()
        try modelContext.save()
        return model.toWireItem()
    }

    /// Returns item counts grouped by state.
    func itemStats() throws -> [String: Int] {
        // Predicate-safe aggregation: fetch every item's `stateRaw` (no
        // predicate, no relationship faulting needed) and bucket in Swift.
        // The local store is small enough that streaming through Swift is
        // cheaper than chasing a `groupBy` SwiftData doesn't expose.
        let descriptor = FetchDescriptor<MarfaItemModel>()
        let models = try modelContext.fetch(descriptor)
        var counts: [String: Int] = [:]
        for model in models {
            counts[model.stateRaw, default: 0] += 1
        }
        return counts
    }

    /// Permanently removes the item. The cascade rule on
    /// `MarfaItemModel.metadata` removes the metadata row in the same
    /// `save()`, so this is one delete + one save end-to-end.
    public func purgeItem(id: String) throws {
        let predicate = #Predicate<MarfaItemModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            // Idempotent: purging a non-existent item is a no-op so the
            // sync engine can replay a server-side delete without first
            // checking whether the row still exists locally.
            return
        }
        modelContext.delete(model)
        try modelContext.save()
    }

    /// Stores (insert or replace) a raw item — used by the sync engine.
    ///
    /// SwiftData has no native upsert; we implement it as fetch-by-id +
    /// in-place mutation, falling through to insert when the row doesn't
    /// exist. Cascade-owned `metadata` is preserved across upserts (we
    /// only mutate the item's own columns).
    public func upsertItem(_ item: Item) throws {
        let id = item.id
        let predicate = #Predicate<MarfaItemModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.apply(item)
        } else {
            let model = MarfaItemModel.make(from: item)
            modelContext.insert(model)
        }
        try modelContext.save()
    }

    /// Stores what an app should see for an item the server just described.
    ///
    /// Two things separate this from ``upsertItem(_:)``, and both are about a
    /// device that is not merely a mirror of the server.
    ///
    /// **A frame behind the row does not apply.** The stored `version` is the
    /// server's own on a row this device has not edited, so a frame naming an
    /// older one describes a state the row has already passed and writing it
    /// would put the row back. The comparison is "not older" rather than
    /// "newer": a reconnect resumes from the cursor and re-delivers the frame
    /// it stopped on, and refusing that would drop a write the store never
    /// made.
    ///
    /// **A queued edit is put back on top.** Without it, a frame from another
    /// device replaced the row wholesale and text someone was still typing
    /// disappeared until the queue drained. Rebasing keeps the local edit
    /// visible *and* lets the other device's change to a different field land,
    /// which replacing and dropping respectively cannot both do.
    ///
    /// The version check is skipped while `edits` is non-empty, and that is a
    /// limitation worth naming rather than an oversight. `updateItem` bumps the
    /// stored `version` on every local edit, so on a row this device is holding
    /// writes for the column is an optimistic guess at what the server will
    /// assign rather than a server fact, and it cannot order anything. The
    /// rebase decides the outcome there instead: the edit survives either way,
    /// and a stale frame can still land in a field the edit does not mention.
    /// Closing that needs the server's version tracked apart from the visible
    /// one, which is a column and therefore a schema version.
    ///
    /// The metadata row is untouched. The server writes metadata through its
    /// own layer and announces it as `metadata.changed`; an item frame carries
    /// the sidecar too, and taking it from here would put one field in two
    /// places and leave the two able to disagree.
    @discardableResult
    public func applyServerItem(_ item: Item, rebasing edits: [PendingItemEdit]) throws -> Bool {
        let id = item.id
        let predicate = #Predicate<MarfaItemModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first

        if let existing, edits.isEmpty, item.version < existing.version {
            return false
        }

        let model: MarfaItemModel
        if let existing {
            existing.apply(item)
            model = existing
        } else {
            model = MarfaItemModel.make(from: item)
            modelContext.insert(model)
        }

        // Oldest first, which is the order the queue replays them in. A device
        // that edited the same field twice has to end up showing the second
        // edit, not the first.
        for edit in edits {
            switch edit {
            case .properties(let delta, let tier, let sourceId):
                var merged = model.properties
                for (key, value) in delta {
                    merged[key] = value
                }
                model.properties = merged
                if let tier { model.tier = tier }
                if let sourceId { model.sourceId = sourceId }
            case .state(let state):
                model.state = state
            }
        }

        try modelContext.save()
        return true
    }

    /// Removes every stored item the server did not send, except the ones a
    /// queued create still owns.
    ///
    /// A row the server purged while this device was away is absent from the
    /// import rather than changed in it, so no event describes it and nothing
    /// else ever corrects it — this pass is the only thing that can.
    ///
    /// `protecting` is what keeps that from destroying work. A row the queue
    /// still holds a create for has never reached the server, so its absence
    /// from the answer says nothing at all, and treating that absence as a
    /// deletion would remove something a person made moments earlier.
    ///
    /// Filtered in Swift rather than in a predicate: `Set.contains` is not
    /// among the shapes SwiftData's predicate engine supports.
    @discardableResult
    public func pruneItems(keeping keptIds: Set<String>, protecting protectedIds: Set<String>) throws -> [String] {
        let models = try modelContext.fetch(FetchDescriptor<MarfaItemModel>())
        var removed: [String] = []
        for model in models where !keptIds.contains(model.id) && !protectedIds.contains(model.id) {
            removed.append(model.id)
            modelContext.delete(model)
        }
        if !removed.isEmpty {
            try modelContext.save()
        }
        return removed
    }

    // MARK: - Edge CRUD

    /// Creates a new edge between two items.
    ///
    /// `id` is the caller's own name for the edge, honored so that the row
    /// written here is the row the caller already refers to; a bulk call
    /// carries one per edge. Omitted, the store mints a UUIDv7. Either way
    /// the id is what a synced replay sends, so the server stores the edge
    /// under it too.
    func createEdge(
        id: String? = nil,
        source: String,
        target: String,
        edgeType: String,
        properties: [String: JSONValue]?
    ) throws -> Edge {
        let now = now()
        let edge = Edge(
            createdAt: now,
            edgeType: edgeType,
            id: id ?? newId(),
            properties: properties ?? [:],
            sourceId: source,
            spaceId: nil,
            targetId: target,
            updatedAt: now
        )
        let model = MarfaEdgeModel.make(from: edge)
        modelContext.insert(model)
        try modelContext.save()
        return edge
    }

    /// Fetches a single edge by ID. Throws ``NotFoundError`` if absent.
    func fetchEdge(id: String) throws -> Edge {
        let predicate = #Predicate<MarfaEdgeModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaEdgeModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw NotFoundError(message: "Edge not found: \(id)")
        }
        return model.toWireEdge()
    }

    /// Lists edges where `sourceId == sourceId`, optionally filtered by
    /// type. Sorted by `createdAt` ascending.
    func fetchEdgesFromSource(
        sourceId: String,
        edgeType: String?,
        cursor: String?,
        limit: Int?
    ) throws -> PaginatedResult<Edge> {
        let typeFilter = edgeType ?? ""
        let hasTypeFilter = edgeType != nil
        let offset = try LocalCursor.validated(cursor) ?? 0
        let predicate = #Predicate<MarfaEdgeModel> { edge in
            (edge.sourceId == sourceId &&
            (!hasTypeFilter || edge.edgeType == typeFilter))
        }
        var descriptor = FetchDescriptor<MarfaEdgeModel>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.createdAt, order: .forward),
                SortDescriptor(\.id, order: .forward),
            ]
        )
        descriptor.fetchOffset = offset
        // One past the limit so truncation is detectable; see `page`.
        if let limit { descriptor.fetchLimit = limit + 1 }
        let models = try modelContext.fetch(descriptor)
        return Self.edgePage(models, limit: limit, offset: offset)
    }

    /// Global edge listing across the entire local store, optionally
    /// filtered by type. Backs `edges.list(edgeType:)`.
    func fetchEdges(
        edgeType: String?,
        cursor: String?,
        limit: Int?
    ) throws -> PaginatedResult<Edge> {
        let typeFilter = edgeType ?? ""
        let hasTypeFilter = edgeType != nil
        let offset = try LocalCursor.validated(cursor) ?? 0
        let predicate = #Predicate<MarfaEdgeModel> { edge in
            !hasTypeFilter || edge.edgeType == typeFilter
        }
        var descriptor = FetchDescriptor<MarfaEdgeModel>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.createdAt, order: .forward),
                SortDescriptor(\.id, order: .forward),
            ]
        )
        descriptor.fetchOffset = offset
        // One past the limit so truncation is detectable; see `page`.
        if let limit { descriptor.fetchLimit = limit + 1 }
        let models = try modelContext.fetch(descriptor)
        return Self.edgePage(models, limit: limit, offset: offset)
    }

    /// Lists edges where `targetId == targetId`, optionally filtered by
    /// type.
    func fetchEdgesToTarget(
        targetId: String,
        edgeType: String?,
        cursor: String?,
        limit: Int?
    ) throws -> PaginatedResult<Edge> {
        let typeFilter = edgeType ?? ""
        let hasTypeFilter = edgeType != nil
        let offset = try LocalCursor.validated(cursor) ?? 0
        let predicate = #Predicate<MarfaEdgeModel> { edge in
            (edge.targetId == targetId &&
            (!hasTypeFilter || edge.edgeType == typeFilter))
        }
        var descriptor = FetchDescriptor<MarfaEdgeModel>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.createdAt, order: .forward),
                SortDescriptor(\.id, order: .forward),
            ]
        )
        descriptor.fetchOffset = offset
        // One past the limit so truncation is detectable; see `page`.
        if let limit { descriptor.fetchLimit = limit + 1 }
        let models = try modelContext.fetch(descriptor)
        return Self.edgePage(models, limit: limit, offset: offset)
    }

    /// Batched inbound-edge lookup. Returns a dictionary keyed by every
    /// distinct target ID in the input (unknown IDs map to an empty
    /// array), with the `limit` applied per target. Single fetch; the
    /// `(targetId, edgeType)` index backs the `IN` clause.
    func fetchEdgesToTargets(
        targetIds: [String],
        edgeType: String?,
        limit: Int?
    ) throws -> [String: [Edge]] {
        guard !targetIds.isEmpty else { return [:] }
        let distinctIds = Array(Set(targetIds))
        let idSet = Set(distinctIds)
        let typeFilter = edgeType ?? ""
        let hasTypeFilter = edgeType != nil
        let predicate = #Predicate<MarfaEdgeModel> { edge in
            idSet.contains(edge.targetId) &&
            (!hasTypeFilter || edge.edgeType == typeFilter)
        }
        let descriptor = FetchDescriptor<MarfaEdgeModel>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let models = try modelContext.fetch(descriptor)

        var result: [String: [Edge]] = Dictionary(
            uniqueKeysWithValues: distinctIds.map { ($0, []) }
        )
        for model in models {
            let edge = model.toWireEdge()
            result[edge.targetId, default: []].append(edge)
        }
        if let limit {
            for (key, edges) in result where edges.count > limit {
                result[key] = Array(edges.prefix(limit))
            }
        }
        return result
    }

    /// Updates an edge's properties.
    func updateEdge(id: String, properties: [String: JSONValue]) throws -> Edge {
        let predicate = #Predicate<MarfaEdgeModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaEdgeModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw NotFoundError(message: "Edge not found: \(id)")
        }
        model.properties = properties
        model.updatedAt = now()
        try modelContext.save()
        return model.toWireEdge()
    }

    /// Deletes an edge by ID. Idempotent — a delete against a missing
    /// row is a no-op so the sync engine can replay an `edge.deleted`
    /// SSE event without first checking whether the row still exists.
    public func deleteEdge(id: String) throws {
        let predicate = #Predicate<MarfaEdgeModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaEdgeModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            return
        }
        modelContext.delete(model)
        try modelContext.save()
    }

    /// Stores (insert or replace) a raw edge — used by the sync engine.
    public func upsertEdge(_ edge: Edge) throws {
        let id = edge.id
        let predicate = #Predicate<MarfaEdgeModel> { $0.id == id }
        var descriptor = FetchDescriptor<MarfaEdgeModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.apply(edge)
        } else {
            let model = MarfaEdgeModel.make(from: edge)
            modelContext.insert(model)
        }
        try modelContext.save()
    }

    // MARK: - Metadata CRUD

    /// Fetches metadata for an item. Returns empty metadata if none
    /// exists (matches the wire-shape `Metadata` for an item with no
    /// row).
    func fetchMetadata(itemId: String) throws -> Metadata {
        let predicate = #Predicate<MarfaMetadataModel> { $0.itemId == itemId }
        var descriptor = FetchDescriptor<MarfaMetadataModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            return Metadata(extensions: [:], itemId: itemId, tags: [])
        }
        return model.toWireMetadata()
    }

    /// Replaces an item's tags with the supplied set, leaving its
    /// extensions untouched.
    ///
    /// Mirrors `PUT /items/{id}/metadata`, which writes the tags column
    /// and nothing else. A synced client writes here and replays that
    /// route, so a local write that cleared the sidecar would disagree
    /// with the server the moment the replay landed — and disagree
    /// silently, since nothing reads the two back against each other.
    @discardableResult
    public func setMetadata(itemId: String, input: MetadataInput) throws -> Metadata {
        try requireItem(itemId)
        let existing = try fetchMetadata(itemId: itemId)
        let metadata = Metadata(
            extensions: existing.extensions,
            itemId: itemId,
            tags: input.tags ?? []
        )
        try writeMetadata(metadata, itemId: itemId)
        return metadata
    }

    /// Stores a metadata row the server sent, replacing whatever is held
    /// locally for that item — used by the sync engine.
    ///
    /// Tags and extensions are two halves of one row on the wire, and the
    /// server sends both together on a `metadata.changed` event and on the
    /// import. Writing them as a unit is what makes a namespace the server
    /// has dropped go away here too; applying the halves separately leaves
    /// a removal with no way to express itself.
    public func upsertMetadata(_ metadata: Metadata) throws {
        try writeMetadata(metadata, itemId: metadata.itemId)
    }

    /// Merges metadata with existing values (set-union for tags;
    /// extensions are preserved).
    @discardableResult
    func mergeMetadata(itemId: String, input: MetadataInput) throws -> Metadata {
        try requireItem(itemId)
        let existing = try fetchMetadata(itemId: itemId)
        let merged = Metadata(
            extensions: existing.extensions,
            itemId: itemId,
            tags: Array(Set(existing.tags + (input.tags ?? [])).sorted())
        )
        try writeMetadata(merged, itemId: itemId)
        return merged
    }

    /// Adds tags to an item (union with existing tags).
    @discardableResult
    func addTags(itemId: String, tags: [String]) throws -> Metadata {
        try mergeMetadata(itemId: itemId, input: MetadataInput(tags: tags))
    }

    /// Removes a single tag from an item.
    func removeTag(itemId: String, tag: String) throws {
        try requireItem(itemId)
        let existing = try fetchMetadata(itemId: itemId)
        let updated = Metadata(
            extensions: existing.extensions,
            itemId: itemId,
            tags: existing.tags.filter { $0 != tag }
        )
        try writeMetadata(updated, itemId: itemId)
    }

    /// Aggregates every distinct tag in use across non-trashed items in
    /// the local store, with usage counts. Sorted count DESC, tag ASC —
    /// matches the server's `GET /metadata/tags` ordering.
    ///
    /// Implementation: fetch every metadata row whose parent item is
    /// non-trashed (single predicate over `item.stateRaw`), then bucket
    /// in Swift over the JSON-decoded tags. Avoids the predicate-engine
    /// blind spot on Codable struct fields (`tagsData`).
    func listTags() throws -> [TagWithCount] {
        // Trashed items contribute no tags — equivalent to a
        // `WHERE state != 'trashed'` filter.
        let trashedRaw = ItemState.trashed.rawValue
        // `item` is the inverse relationship — only metadata rows
        // attached to a non-trashed item count. A nil `item` (orphan)
        // contributes nothing (no JOIN match). The predicate
        // engine requires a single expression, hence the `&&` chain
        // rather than an `if let`.
        let predicate = #Predicate<MarfaMetadataModel> { meta in
            meta.item != nil && meta.item?.stateRaw != trashedRaw
        }
        var descriptor = FetchDescriptor<MarfaMetadataModel>(predicate: predicate)
        // Fault the parent item alongside the metadata rows so we don't
        // pay a per-row materialization cost when the predicate engine
        // walks the relationship.
        descriptor.relationshipKeyPathsForPrefetching = [\.item]
        let models = try modelContext.fetch(descriptor)
        var counts: [String: Int] = [:]
        for model in models {
            for tag in model.tags {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .map { TagWithCount(tag: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tag < rhs.tag
            }
    }

    // MARK: - Extension CRUD

    /// Writes data to a namespaced extension on an item, merging it into
    /// any existing extensions map. Returns the full extensions
    /// dictionary in the namespace-keyed shape callers see.
    @discardableResult
    func setExtension(
        itemId: String,
        namespace: String,
        data: [String: JSONValue]
    ) throws -> [String: [String: JSONValue]] {
        try requireItem(itemId)
        let existing = try fetchMetadata(itemId: itemId)
        var map = Self.unwrapExtensions(existing.extensions)
        map[namespace] = data
        let merged = Metadata(
            extensions: Self.wrapExtensions(map),
            itemId: itemId,
            tags: existing.tags
        )
        try writeMetadata(merged, itemId: itemId)
        return map
    }

    /// Removes a namespaced extension from an item.
    func deleteExtension(itemId: String, namespace: String) throws {
        try requireItem(itemId)
        let existing = try fetchMetadata(itemId: itemId)
        var map = Self.unwrapExtensions(existing.extensions)
        map.removeValue(forKey: namespace)
        let merged = Metadata(
            extensions: Self.wrapExtensions(map),
            itemId: itemId,
            tags: existing.tags
        )
        try writeMetadata(merged, itemId: itemId)
    }

    /// Returns all extension namespaces for an item.
    func fetchExtensions(itemId: String) throws -> [String: [String: JSONValue]] {
        Self.unwrapExtensions(try fetchMetadata(itemId: itemId).extensions)
    }

    /// Returns a single extension namespace for an item, or `nil` if
    /// absent.
    func fetchExtension(itemId: String, namespace: String) throws -> [String: JSONValue]? {
        try fetchExtensions(itemId: itemId)[namespace]
    }

    // MARK: - Private helpers

    /// Refuses a metadata or extension write against an item this store does
    /// not hold, the way every one of those routes refuses it server-side.
    ///
    /// Without this the write succeeds and orphans itself: a metadata row is
    /// attached to its parent only at the moment it is inserted, and
    /// `upsertItem` never adopts a row already sitting there — so the item
    /// arriving later does not repair it. The row is then invisible to every
    /// read that reaches metadata through the item, and no second write fixes
    /// it either, because the row now exists and the insert path is the only
    /// one that attaches.
    private func requireItem(_ itemId: String) throws {
        let predicate = #Predicate<MarfaItemModel> { $0.id == itemId }
        var descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).first != nil else {
            throw NotFoundError(message: "Item \(itemId) not found")
        }
    }

    /// Upsert path for the metadata row. Looks up by `itemId`, mutates
    /// in place, or inserts a fresh row attached to the parent item if
    /// one exists. Always one save.
    private func writeMetadata(_ metadata: Metadata, itemId: String) throws {
        let metaPredicate = #Predicate<MarfaMetadataModel> { $0.itemId == itemId }
        var metaDescriptor = FetchDescriptor<MarfaMetadataModel>(predicate: metaPredicate)
        metaDescriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(metaDescriptor).first {
            existing.apply(metadata)
            try modelContext.save()
            return
        }
        let model = MarfaMetadataModel.make(from: metadata)
        modelContext.insert(model)
        // Attach to the parent item's relationship if the item exists,
        // so cascade-on-purge fires correctly.
        let itemPredicate = #Predicate<MarfaItemModel> { $0.id == itemId }
        var itemDescriptor = FetchDescriptor<MarfaItemModel>(predicate: itemPredicate)
        itemDescriptor.fetchLimit = 1
        if let parent = try modelContext.fetch(itemDescriptor).first {
            parent.metadata = model
        }
        try modelContext.save()
    }

    // Items descriptor — shared by `fetchItems`, `fetchItemsWithMetadata`,
    // and the ItemQuery / ItemsWithMetadataQuery refetch paths via the
    // `nonisolated` static helpers.
    ///
    /// **What a local list still does not narrow on.** `source`, `filter`,
    /// `edge` and `backref` are accepted and ignored here. `filter` is the
    /// server's structured expression and is not evaluated locally, matching
    /// how `LocalStoreSearch` treats `SearchFilters.filter`; the other three
    /// have no local implementation yet. Listed rather than left silent,
    /// because a filter that is quietly dropped is indistinguishable from one
    /// that matched everything, and that is the defect this file just spent
    /// two changes repairing.
    nonisolated static func makeItemsDescriptor(filters: ListFilters?) -> FetchDescriptor<MarfaItemModel> {
        // Captured-value short-circuit pattern (predicate convention 8):
        // SwiftData has no runtime `Predicate<T>` composition, so we
        // capture booleans alongside string defaults and let the
        // predicate engine optimize constant-true branches away.
        let typeFilter = filters?.type ?? ""
        let hasTypeFilter = filters?.type != nil
        let stateFilter = filters?.state?.rawValue ?? ""
        let hasStateFilter = filters?.state != nil
        let since = filters?.since ?? ""
        let hasSince = filters?.since != nil
        let until = filters?.until ?? ""
        let hasUntil = filters?.until != nil
        // `TierFilter` and `Tier` share their raw values, so the filter
        // compares directly against the stored column.
        let tierFilter = filters?.tier?.rawValue ?? ""
        let hasTierFilter = filters?.tier != nil

        // The date bounds narrow here but do not decide here. The server
        // compares `COALESCE(timestamp, created_at)`, and a row that reached
        // this store from a server with no timestamp holds `""`, so the
        // honest comparison needs both columns. Naming both, twice, pushes
        // the macro past what the type-checker accepts, and this predicate is
        // shared with every reactive query.
        //
        // So SQL narrows on `timestamp` and deliberately lets every empty one
        // through, and `applyDateBounds` settles those few against
        // `createdAt` afterwards. Permissive rather than strict on purpose: a
        // row wrongly excluded here cannot be recovered later, whereas one
        // wrongly included is dropped a moment later at no cost.
        let predicate = #Predicate<MarfaItemModel> { item in
            (!hasTypeFilter  || item.type == typeFilter) &&
            (!hasStateFilter || item.stateRaw == stateFilter) &&
            (!hasSince || item.timestamp >= since || item.timestamp == "") &&
            (!hasUntil || item.timestamp <= until) &&
            (!hasTierFilter  || item.tierRaw == tierFilter)
        }

        var descriptor = FetchDescriptor<MarfaItemModel>(
            predicate: predicate,
            sortBy: Self.sortDescriptors(filters: filters)
        )
        // The cursor advances the window rather than narrowing the predicate.
        // A keyset boundary is what the server uses and was tried first here,
        // but naming a sort column and both directions inside `#Predicate`
        // pushes the macro past what the type-checker will accept, and the
        // predicate is shared with every reactive query — not somewhere to
        // spend that budget. See `LocalCursor` for what this costs.
        if let raw = filters?.cursor, let offset = LocalCursor.offset(decoding: raw) {
            descriptor.fetchOffset = offset
        }
        if let limit = filters?.limit {
            descriptor.fetchLimit = limit
        }
        return descriptor
    }

    /// Shared sort descriptors honoring `filters.sort` / `filters.direction`.
    /// Default is `updatedAt` DESC, matching the server's
    /// `GET /items` default. Falls back to `updatedAt` for any
    /// unsupported sort key — predicate-safe access only.
    ///
    /// `id` is a second descriptor rather than decoration: rows sharing a
    /// sort value would otherwise come back in whatever order the store felt
    /// like, and a keyset cursor over an unstable order skips or repeats rows
    /// at every page boundary. It follows the primary direction, as the
    /// server's system-column sort does.
    nonisolated static func sortDescriptors(filters: ListFilters?) -> [SortDescriptor<MarfaItemModel>] {
        let order: SortOrder = filters?.direction == .ascending ? .forward : .reverse
        let primary: SortDescriptor<MarfaItemModel>
        switch filters?.sort?.rawValue ?? "updated_at" {
        case "created_at": primary = SortDescriptor(\.createdAt, order: order)
        case "timestamp":  primary = SortDescriptor(\.timestamp, order: order)
        default:           primary = SortDescriptor(\.updatedAt, order: order)
        }
        return [primary, SortDescriptor(\.id, order: order)]
    }

    // Each namespace's stored value is an object. The wire type models
    // the extensions map as `[String: JSONValue]`, but every namespace
    // holds a dictionary in practice. These helpers translate between
    // the wire shape and the namespace-keyed `[String: [String: JSONValue]]`
    // view callers of `fetchExtensions` see.
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
