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
        let offset = try LocalCursor.validated(filters?.cursor) ?? 0
        // One row past the limit, so truncation is known without a second
        // count query. The extra row is dropped before the caller sees it.
        var probe = filters
        if let limit = filters?.limit { probe?.limit = limit + 1 }
        let models = try modelContext.fetch(Self.makeItemsDescriptor(filters: probe))
        let page = Self.page(models, limit: filters?.limit)
        return PaginatedResult(
            data: page.rows.map { $0.toWireItem() },
            cursor: page.hasMore ? LocalCursor(o: offset + page.rows.count).encoded() : nil,
            hasMore: page.hasMore
        )
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
        let itemModels = try modelContext.fetch(Self.makeItemsDescriptor(filters: filters))
        return try joinMetadata(itemModels)
    }

    /// The paginated form, for callers that page rather than take everything.
    /// Shares the join below, so the two cannot drift on how metadata is
    /// matched or how duplicate rows are resolved.
    func fetchItemsWithMetadataPage(
        filters: ListFilters?
    ) throws -> PaginatedResult<ItemWithMetadata> {
        let offset = try LocalCursor.validated(filters?.cursor) ?? 0
        var probe = filters
        if let limit = filters?.limit { probe?.limit = limit + 1 }
        let models = try modelContext.fetch(Self.makeItemsDescriptor(filters: probe))
        let page = Self.page(models, limit: filters?.limit)
        return PaginatedResult(
            data: try joinMetadata(page.rows),
            cursor: page.hasMore ? LocalCursor(o: offset + page.rows.count).encoded() : nil,
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

    /// Replaces all metadata for an item (tags only — `extensions` is
    /// reset to empty; the `setMetadata` contract is replace, not merge).
    @discardableResult
    public func setMetadata(itemId: String, input: MetadataInput) throws -> Metadata {
        let metadata = Metadata(
            extensions: [:],
            itemId: itemId,
            tags: input.tags ?? []
        )
        try writeMetadata(metadata, itemId: itemId)
        return metadata
    }

    /// Merges metadata with existing values (set-union for tags;
    /// extensions are preserved).
    @discardableResult
    func mergeMetadata(itemId: String, input: MetadataInput) throws -> Metadata {
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

        let predicate = #Predicate<MarfaItemModel> { item in
            (!hasTypeFilter  || item.type == typeFilter) &&
            (!hasStateFilter || item.stateRaw == stateFilter) &&
            (!hasSince       || item.updatedAt >= since) &&
            (!hasUntil       || item.updatedAt <= until)
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
