# SwiftData Migration — MymeSDK Phase 1 (CloudKit-ready storage)

**Branch:** `feat/swiftdata-migration` (worktree off `main` at `~/aic-local/Dev/MymeHQ/swift-sdk/`)
**Target version:** `4.0.0`
**Plan companion in worktree:** copy this file to `SWIFTDATA_MIGRATION_PLAN.md` at the worktree root once execution begins.

---

## 1. Context

The Myme Swift SDK currently persists on-device data in SQLite via GRDB 7. Two consumer apps (myme-notes, myme-messages) ship against `MymeSDK 3.5.x`. The SDK is pre-release, has no external users, and is gated by a single source of truth: the CloudKit/iCloud project documented at `~/aic-vault/Projects/myme-A1ZB0/Artifacts/36-cloudkit-implementation/CloudKit Implementation.md`.

That project commits the Notes app to a third sync mode — **iCloud** — alongside Local and Myme. iCloud sync is implemented as `cloudKitDatabase: .automatic` mirroring on the same SwiftData store the app already uses. Phase 1, this work, ports the SDK's storage layer from GRDB to SwiftData with a CloudKit-compatible schema. **CloudKit sync is unlocked but not enabled** — `cloudKitDatabase: .none` in this PR. Phase 2 (Notes app) flips the switch.

Everything above the storage layer — `SyncEngine`, `MutationQueue`'s replay/cursor logic, `ConnectionStateManager`, the SSE consumer, the namespace local-first behaviour, the public reactive query types — stays semantically identical. Only the storage calls underneath change.

**Source-of-truth references:**
- `~/aic-vault/Projects/myme-A1ZB0/Artifacts/36-cloudkit-implementation/CloudKit Implementation.md` (primary)
- `~/aic-vault/Projects/myme-A1ZB0/Platform/Swift SDK.md` (SDK overview)
- `~/aic-local/Dev/MymeHQ/swift-sdk/CLAUDE.md` (repo rules)

**Decisions confirmed by orchestrator before planning:**
- Public factories `MymeClient.local(_:)` and `MymeClient.synced(...)` become `async throws` (Q1).
- `MymeEdgeModel` uses string ids only; no `@Relationship` to items (Q2).
- SDK minimum bumps to **iOS 26 / iPadOS 26 / macOS 26 / visionOS 26 / watchOS 26 / tvOS 26**. `#Index` and other iOS 26-era SwiftData APIs available (Q3).
- Six `@Model` classes (the implementation doc undercounted; PendingBlob persists as its own model with `@Attribute(.externalStorage)`). To be flagged for vault-doc correction post-merge (Q4).

---

## 2. Schema — six `@Model` classes

All models live in `Sources/MymeSDK/LocalStore/Schema/V1/`. Naming convention: each adds the `Model` suffix to avoid colliding with the wire types `Item` / `Edge` / `Metadata` (`Sources/MymeSDK/Types/Wire/Generated/`).

### CloudKit-driven invariants applied to every model

- No `#Unique`, no `@Attribute(.unique)`. Uniqueness comes from UUIDv7 (`Sources/MymeSDK/LocalStore/UUIDv7.swift`) at insertion time. Logical de-dup uses fetch-by-id + replace.
- Every property has a default value or is optional.
- All relationships explicit `@Relationship(deleteRule:inverse:)`, never `.deny`, both sides optional. Inverse declared on one side only.
- No property literally named `description`.
- `[String: JSONValue]` blobs persist as `Data` (UTF-8 JSON) with a non-persisted computed accessor (`@Transient`-style) for ergonomic read/write. Predicates over property values are out of scope (search belongs to a future index, not the model).
- Codable enums (`ItemState`, `Origin`, `MutationKind`) persist as their `String` rawValue — predicate-safe under the rule "compare against rawValue, not the case".
- `[String]` (tags) persists as JSON-encoded `Data` for parity with the wire shape `Metadata.tags: [String]` and to keep one round-trip path through the existing `JSONEncoder`/`JSONDecoder`.

### 2.1 `MymeItemModel` — maps `LocalStore.swift:65-82`

```swift
@Model
public final class MymeItemModel {
    public var id: String = ""              // UUIDv7
    public var type: String = ""
    public var stateRaw: String = ItemState.active.rawValue
    public var propertiesData: Data = Data("{}".utf8)
    public var source: String = ""
    public var sourceId: String?
    public var originRaw: String = Origin.user.rawValue
    public var library: Bool = false
    public var version: Int = 1
    public var schemaVersion: Int = 1
    public var createdAt: String = ""       // ISO 8601
    public var updatedAt: String = ""
    public var timestamp: String = ""
    public var device: String?
    public var captureLatitude: Double?
    public var captureLongitude: Double?

    @Relationship(deleteRule: .cascade, inverse: \MymeMetadataModel.item)
    public var metadata: MymeMetadataModel?

    public init() {}
}

#Index<MymeItemModel>([\.type, \.stateRaw], [\.updatedAt], [\.id])
```

- `state` and `origin` are exposed via computed `var state: ItemState { get/set }` / `var origin: Origin { get/set }` outside the macro (regular Swift, not `@Transient`-needed since they wrap stored `*Raw` strings).
- `properties: [String: JSONValue]` is a computed accessor wrapping `propertiesData` through the same encode/decode path that exists today in `LocalStoreRecords.swift:44-93`.
- `metadata` cascade ensures `purgeItem` is one delete + one save.
- `#Index` on `(type, stateRaw)` and `(updatedAt)` mirrors the existing GRDB indexes `idx_items_type_state` and `idx_items_updated_at` (`LocalStore.swift:101-111`). The `(id)` index supports lookup-by-id which today rides on `id TEXT PRIMARY KEY`.

### 2.2 `MymeEdgeModel` — maps `LocalStore.swift:84-93`

```swift
@Model
public final class MymeEdgeModel {
    public var id: String = ""              // UUIDv7
    public var sourceId: String = ""
    public var targetId: String = ""
    public var edgeType: String = ""
    public var propertiesData: Data = Data("{}".utf8)
    public var tenantId: String?
    public var createdAt: String = ""
    public var updatedAt: String = ""

    public init() {}
}

#Index<MymeEdgeModel>([\.sourceId, \.edgeType], [\.targetId, \.edgeType], [\.id])
```

**No `@Relationship` to `MymeItemModel` (orchestrator decision Q2).** Edges may dangle today and that behaviour is preserved — the SDK upserts edges via SSE without checking whether their endpoints exist locally yet. Predicates use the string columns exclusively, which keeps them CloudKit-safe and avoids the per-upsert hydration cost. SwiftData change-tracking still fires on edge mutations regardless.

`#Index` mirrors `idx_edges_source` and `idx_edges_target`.

### 2.3 `MymeMetadataModel` — maps `LocalStore.swift:95-99`

```swift
@Model
public final class MymeMetadataModel {
    public var itemId: String = ""
    public var tagsData: Data = Data("[]".utf8)
    public var extensionsData: Data = Data("{}".utf8)

    @Relationship(deleteRule: .nullify, inverse: \MymeItemModel.metadata)
    public var item: MymeItemModel?

    public init() {}
}

#Index<MymeMetadataModel>([\.itemId])
```

- `tags: [String]` and `extensions: [String: [String: JSONValue]]` are computed accessors over the JSON `Data` blobs.
- The inverse of the cascade rule on `MymeItemModel.metadata`. `.nullify` here means: deleting only the metadata row leaves the item intact (used by `removeTag` corner cases via merge logic).

### 2.4 `PendingMutationModel` — maps `MutationQueue.swift:159-168`

```swift
@Model
public final class PendingMutationModel {
    public var id: String = ""              // UUIDv4 (preserved)
    public var kindRaw: String = ""         // MutationKind.rawValue
    public var payloadJson: String = "{}"
    public var sourceId: String?
    public var localId: String?
    public var createdAt: String = ""       // ISO 8601 — drives drain order
    public var attemptCount: Int = 0
    public var lastError: String?

    public init() {}
}

#Index<PendingMutationModel>([\.createdAt], [\.localId], [\.kindRaw])
```

- `var kind: MutationKind { get/set }` wraps `kindRaw`.
- `MutationKind` lifted out of `PendingMutationRecord.Kind` (`MutationQueue.swift:10-16`) into `Sources/MymeSDK/Sync/MutationKind.swift` as `public enum MutationKind: String, Codable, Sendable, CaseIterable { case createItem, updateItem, deleteItem, restoreItem, transitionItem, purgeItem, createEdge, updateEdge, deleteEdge, setMetadata, mergeMetadata, addTags, removeTag, setExtension, deleteExtension, uploadBlob }`.
- `PendingMutationRecord` becomes a Sendable DTO struct (preserved in `MutationQueue.swift`) so `SyncEngine.replayRecord(_:decoder:)` and friends are unchanged. The `@ModelActor` translates between `PendingMutationModel` and `PendingMutationRecord` at the boundary.
- Indexes back the drain-order sort, the cascade scans (`MutationQueue.swift:486-528, 565-624`), and the `kind == .createEdge` predicate path.

### 2.5 `SyncStateModel` — maps `MutationQueue.swift:169-172`

```swift
@Model
public final class SyncStateModel {
    public var key: String = ""
    public var value: String = ""

    public init() {}
}

#Index<SyncStateModel>([\.key])
```

Two known keys today: `last_event_id`, `last_full_sync_at`. Upsert semantics preserved by `saveSyncState`: fetch-by-key, update-or-insert, save.

### 2.6 `PendingBlobModel` — maps `MutationQueue.swift:187-191`

```swift
@Model
public final class PendingBlobModel {
    public var hash: String = ""            // "sha256:hex"
    @Attribute(.externalStorage) public var data: Data = Data()
    public var mimeType: String = ""

    public init() {}
}

#Index<PendingBlobModel>([\.hash])
```

`@Attribute(.externalStorage)` is a *suggestion* per Apple docs — SwiftData stores the bytes in a sibling file when the blob is large enough. Critical for the multi-MB image / video uploads the consumer apps push.

No relationship to `PendingMutationModel`. The existing design (`MutationQueue.swift:177-192`) deliberately decouples blob bytes from mutation rows so `payloadJson` stays lean and one blob can back many mutations (SHA-256 dedup). Atomicity preserved by writing both rows in a single `ModelContext.save()` (§4.3).

---

## 3. Schema versioning + migration plan

### 3.1 V1 declaration

`Sources/MymeSDK/LocalStore/Schema/V1/MymeSchemaV1.swift`:

```swift
import SwiftData

public enum MymeSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [
            MymeItemModel.self,
            MymeEdgeModel.self,
            MymeMetadataModel.self,
            PendingMutationModel.self,
            SyncStateModel.self,
            PendingBlobModel.self,
        ]
    }
}
```

### 3.2 Migration plan from day one

`Sources/MymeSDK/LocalStore/Schema/MymeMigrationPlan.swift`:

```swift
import SwiftData

public enum MymeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [MymeSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
```

Empty stages are valid. No GRDB-to-SwiftData migration is required — the SDK is pre-release; consumer local stores are scrapped on upgrade (release notes call it out). Adding V2 later means: copy `Schema/V1/` to `Schema/V2/`, change models, append `MymeSchemaV2.self` to `schemas`, append a `MigrationStage` to `stages`.

### 3.3 Container construction

`Sources/MymeSDK/LocalStore/MymeModelContainer.swift`:

```swift
import Foundation
import SwiftData

@_spi(MymeSDKTestSupport) public enum MymeModelContainer {
    public static func make(path: String) throws -> ModelContainer {
        if path == ":memory:" {
            return try ModelContainer(
                for: MymeSchemaV1.self,
                migrationPlan: MymeMigrationPlan.self,
                configurations: ModelConfiguration(
                    "myme",
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
            )
        }
        let url = URL(fileURLWithPath: path)
        return try ModelContainer(
            for: MymeSchemaV1.self,
            migrationPlan: MymeMigrationPlan.self,
            configurations: ModelConfiguration(
                "myme",
                schema: Schema(MymeSchemaV1.models),
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none // Phase 1 ships .none; Phase 2 flips to .automatic
            )
        )
    }
}
```

`@_spi(MymeSDKTestSupport)` exposes the constructor to `MymeSDKTestSupport` only — the public SDK surface stays clean. Consumers still go through `MymeClient.local(_:)` / `MymeClient.synced(...)`.

---

## 4. `@ModelActor` design

### 4.1 LocalStore as `@ModelActor`

```swift
@ModelActor
public actor LocalStore {
    // @ModelActor synthesises:
    //   public init(modelContainer: ModelContainer)
    //   public let modelExecutor: any ModelExecutor
    //   public let modelContainer: ModelContainer
    //   nonisolated var modelContext: ModelContext { … }
    //
    // All existing public method signatures preserved:
    //   createItem, fetchItem, fetchItems, fetchItemsWithMetadata,
    //   updateItem, trashItem, restoreItem, transitionItem, itemStats,
    //   purgeItem, upsertItem,
    //   createEdge, fetchEdge, fetchEdgesFromSource, fetchEdges,
    //   fetchEdgesToTarget, fetchEdgesToTargets, updateEdge, deleteEdge,
    //   upsertEdge,
    //   fetchMetadata, setMetadata, mergeMetadata, addTags, removeTag,
    //   listTags,
    //   setExtension, deleteExtension, fetchExtensions, fetchExtension
}
```

Each method body becomes a `FetchDescriptor` build → `modelContext.fetch(...)` (or `.insert(...)` / `.delete(...)` / `.save()`) → mapping the result `MymeItemModel` (etc.) into the wire `Item` struct (defined in `Sources/MymeSDK/Types/Wire/Generated/Item.swift`) before returning. **Wire types — not `@Model` instances — cross the actor boundary.** This satisfies the "models never cross actors" rule from Apple's SwiftData docs while keeping the `LocalStore` API byte-identical.

The mapping helpers (`MymeItemModel.toWireItem()`, `static MymeItemModel.from(wireItem:)`, plus equivalents for `Edge` and `Metadata`) live in `Sources/MymeSDK/LocalStore/Schema/V1/Mappers.swift` — one file, reusable by `MutationQueue` and the reactive layer. Use the existing `JSONEncoder` / `JSONDecoder` from `LocalStoreRecords.swift:1-15` (preserved verbatim, just relocated).

### 4.2 MutationQueue as `@ModelActor`

```swift
@ModelActor
public actor MutationQueue {
    // Public methods unchanged in signature:
    //   isEmpty,
    //   loadSyncState(key:), saveSyncState(key:value:), clearSyncState(key:),
    //   fetchAll(), remove(id:), recordFailure(id:error:),
    //   rewriteLocalId(from:to:),
    //   dropMutationsReferencingLocalId(_:),
    //   fetchPendingBlob(hash:), deletePendingBlob(hash:),
    //   enqueueCreateItem, enqueueUpdateItem, enqueueDeleteItem,
    //   enqueueRestoreItem, enqueueTransitionItem, enqueuePurgeItem,
    //   enqueueCreateEdge, enqueueUpdateEdge, enqueueDeleteEdge,
    //   enqueueSetMetadata, enqueueMergeMetadata, enqueueAddTags,
    //   enqueueRemoveTag, enqueueSetExtension, enqueueDeleteExtension,
    //   enqueueBlobUpload
}
```

**Critical:** receives the **same `ModelContainer`** as `LocalStore`. Both actors hold their own `ModelContext`, but the underlying SQLite store is one. Cross-actor saves serialise at the SQLite layer.

`fetchAll()`:
```swift
let descriptor = FetchDescriptor<PendingMutationModel>(
    sortBy: [SortDescriptor(\.createdAt, order: .forward)]
)
let models = try modelContext.fetch(descriptor)
return models.map { PendingMutationRecord(from: $0) }
```

`PendingMutationRecord` becomes a value DTO `struct PendingMutationRecord: Sendable` with the same field set the SyncEngine consumes today. The actor maps between model and record at the boundary.

### 4.3 Atomicity guarantees

Three transaction guarantees from the GRDB code that survive the port:

1. **`enqueueBlobUpload` — blob row + mutation row in one transaction** (`MutationQueue.swift:332-358`). Becomes:
   ```swift
   modelContext.insert(blobModel)
   modelContext.insert(mutationModel)
   try modelContext.save()
   ```
   Single `save()` commits both as one SQLite transaction.

2. **`purgeItem` — item + cascade-deleted metadata in one transaction** (`LocalStore.swift:380-385`). Becomes:
   ```swift
   guard let item = try modelContext.fetch(/* by id */).first else { throw … }
   modelContext.delete(item)
   try modelContext.save()
   ```
   Cascade rule on `MymeItemModel.metadata` removes the metadata row in the same save.

3. **`dropMutationsReferencingLocalId` — three-pass scan in one transaction** (`MutationQueue.swift:565-624`). Three sequential `modelContext.fetch` calls, multiple `.delete`s, single trailing `try modelContext.save()`. SwiftData groups every `delete` between saves into one commit.

Each is covered by an explicit acceptance test (§7.2).

### 4.4 Off-main construction

`@ModelActor`'s synthesised init binds the actor's executor to whatever actor calls it. Calling from `@MainActor` silently runs every method on main. Apple's documented mitigation is `Task.detached { LocalStore(modelContainer: container) }.value`. The factory wraps construction in `Task.detached`, which forces the executor onto the cooperative thread pool.

This is the reason the public factories must become `async throws` (Q1).

### 4.5 Public factory signatures

```swift
// Before                                                  // After
public static func local(path: String) throws -> Client    public static func local(path: String) async throws -> Client
public static func synced(url: URL, apiKey: String,        public static func synced(url: URL, apiKey: String,
   storePath: String,                                          storePath: String,
   connectionManager: ConnectionStateManager?)                 connectionManager: ConnectionStateManager?)
   throws -> Client                                            async throws -> Client
```

`makeStore()` stays sync. All namespace methods (already `async throws`) unchanged.

`MymeClient`'s internal field `private let pool: DatabasePool?` (`MymeClient.swift:65`) becomes `private let container: ModelContainer?`. `makeStore()` returns `container.map(MymeStore.init(container:))`.

`LocalStoreError` (`Sources/MymeSDK/LocalStore/LocalStoreRecords.swift:208-211`) moves to `Sources/MymeSDK/LocalStore/LocalStoreError.swift` and gains `case migrationFailed(String)` and `case modelMissing(id: String)`.

---

## 5. Reactive layer rebuild

Public surface byte-identical: every field, every method, every factory signature on `MymeStore` and the seven query types stays the same. Only the internals change.

### 5.1 `MymeStore` holds the container

`Sources/MymeSDK/Reactive/MymeStore.swift`:

```swift
@Observable @MainActor
public final class MymeStore {
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }
    // factory methods unchanged in signature; pass `container` instead of `pool`
}
```

Each query type opens its own `ModelContext(container)` on `@MainActor` — `ModelContext` is **not** `Sendable`, so it never crosses an actor hop.

### 5.2 didSave + debounced refetch — the universal pattern

GRDB's `ValueObservation.tracking { db in … }.start(in: pool, scheduling: .mainActor, …)` is replaced with `NotificationCenter` subscription to `ModelContext.didSave` plus a 50ms debounce, then a refetch. Pattern, applied to every query (showing `ItemQuery` representatively):

```swift
@Observable @MainActor
public final class ItemQuery {
    public private(set) var items: [Item] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    private let context: ModelContext
    private let filters: ListFilters?
    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?

    init(container: ModelContainer, filters: ListFilters?) {
        self.context = ModelContext(container)
        self.filters = filters
        Task { @MainActor in await self.refetch() }
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil, // any context against this container
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefetch() }
        }
    }

    private func scheduleRefetch() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(RefreshDebounce.interval))
            guard !Task.isCancelled else { return }
            await self.refetch()
        }
    }

    private func refetch() async { /* FetchDescriptor → fetch → assign */ }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        debounceTask?.cancel()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
```

**`object: nil`** — we want changes from any context against the same container, because `LocalStore` and `MutationQueue` write from their own actor-bound contexts, not from `MymeStore`'s context.

**Debounce 50ms** — bulk SSE catch-up regularly applies dozens of upserts in tens of milliseconds. A 50ms coalesce window collapses bursts into one fetch without visible lag (≈ 3 frames at 60Hz). Single constant in `Sources/MymeSDK/Reactive/RefreshDebounce.swift` so we can tune in one place.

### 5.3 Predicate composition pattern

SwiftData `#Predicate` does not support runtime composition of multiple `Predicate<T>` values. The captured-value pattern is the established workaround:

```swift
let typeFilter: String = filters?.type ?? ""
let hasTypeFilter = !typeFilter.isEmpty
let stateFilter: String = filters?.state?.rawValue ?? ""
let hasStateFilter = !stateFilter.isEmpty
let since = filters?.since ?? ""
let hasSince = !since.isEmpty
let until = filters?.until ?? ""
let hasUntil = !until.isEmpty

var descriptor = FetchDescriptor<MymeItemModel>(
    predicate: #Predicate { item in
        (!hasTypeFilter  || item.type == typeFilter) &&
        (!hasStateFilter || item.stateRaw == stateFilter) &&
        (!hasSince       || item.updatedAt >= since) &&
        (!hasUntil       || item.updatedAt <= until)
    }
)
descriptor.sortBy = [Self.sortDescriptor(filters: filters)]
if let limit = filters?.limit { descriptor.fetchLimit = limit }
```

Captured booleans short-circuit at the predicate engine; constant-true branches optimise away. **Note:** the predicate compares `item.stateRaw == stateFilter` (string), not `item.state == .active` (enum), per predicate-safety rule 8 (§6).

### 5.4 Per-query notes

- **`ItemQuery`** — pattern above.
- **`TypedItemQuery<T: MymeItem>`** — pattern above + extra clause `item.type == T.typeIdentifier`. Result mapped through `T.init?(from:)` (preserved from `ItemQuery.swift:160-167`).
- **`SingleItemQuery`** — `FetchDescriptor` with `predicate: #Predicate { $0.id == capturedId }`, `fetchLimit = 1`. `item` is `nil` when fetch returns empty.
- **`EdgesQuery`** (two flavours, both preserved) — outbound: predicate on `sourceId`. By-type-only: predicate on `edgeType`. Sort by `createdAt` ascending. Always uses string-id columns.
- **`BackrefsQuery`** — `predicate: #Predicate { ids.contains($0.targetId) }` where `ids = Set(targetIds)`. Result grouped into `[targetId: [Edge]]` in Swift. Empty-input early return preserved (`BackrefsQuery.swift:65-72`).
- **`TagsQuery`** — pure-Swift aggregation replaces today's raw SQL `json_each` (`TagsQuery.swift:50-66`):
   ```swift
   var descriptor = FetchDescriptor<MymeMetadataModel>(
       predicate: #Predicate { $0.item?.stateRaw != ItemState.trashed.rawValue }
   )
   descriptor.relationshipKeyPathsForPrefetching = [\.item]
   let rows = try context.fetch(descriptor)
   var counts: [String: Int] = [:]
   for row in rows { for tag in row.tags { counts[tag, default: 0] += 1 } }
   self.tags = counts.map { TagWithCount(tag: $0.key, count: $0.value) }
       .sorted { lhs, rhs in lhs.count != rhs.count ? lhs.count > rhs.count : lhs.tag < rhs.tag }
   ```
   `relationshipKeyPathsForPrefetching` avoids per-row faulting. Ordering matches the existing GRDB SQL (count DESC, tag ASC).
- **`ItemsWithMetadataQuery`** — items fetch with the same descriptor as `ItemQuery`, then a single batched fetch over metadata where `ids.contains($0.itemId)`, then build `[ItemWithMetadata]` exactly as today (`ItemsWithMetadataQuery.swift:75-94`).

### 5.5 AsyncStream surfaces preserved

The two public AsyncStream surfaces stay AsyncStream — they belong to actors we don't touch:
- `SyncEngine.events: AsyncStream<SyncEvent>` (`Sources/MymeSDK/Sync/SyncEngine.swift`)
- `ConnectionStateManager.stateUpdates: AsyncStream<ConnectionState>` (`Sources/MymeSDK/Sync/ConnectionStateManager.swift`)

The reactive query types do not expose AsyncStream — they are `@Observable`. No change.

---

## 6. Predicate-safety conventions

A new file `Sources/MymeSDK/LocalStore/Schema/PredicateConventions.swift` carries doc-only block comments stating the rules. A short `// MARK: - Predicate safety` comment is prepended to every reactive query file so editors don't have to chase the conventions file.

**The rules, byte-for-byte:**

```
// 1. Never use `prop.isEmpty == false` — use `!prop.isEmpty`. The first
//    compiles cleanly and crashes at runtime.
// 2. No regular expressions in predicates — they compile and crash at runtime.
// 3. No computed properties in predicates — only stored columns.
// 4. No predicates inside Codable struct fields — `propertiesData`,
//    `tagsData`, `extensionsData` are opaque to the predicate engine.
//    Fetch then filter in Swift if you need to.
// 5. Use `starts(with:)`, never `hasSuffix(_:)` (unsupported).
// 6. For case-insensitive contains, use `localizedStandardContains(_:)`,
//    not `lowercased().contains(_:)`.
// 7. Codable enum equality: predicate against the rawValue string, e.g.
//    `$0.stateRaw == "active"` — NOT `$0.state == .active`. The latter
//    compiles but lowers fragilely under CloudKit.
// 8. Compose predicates with captured values + boolean short-circuits;
//    do NOT attempt to combine `Predicate<T>` instances at runtime.
//    See ItemQuery.makeDescriptor for the canonical pattern.
```

Every predicate is exercised in `Tests/MymeSDKTests/PredicateSafetyTests.swift` (§7.3).

---

## 7. Test rewrite

### 7.1 Files needing rewrite (storage-touching)

All in `Tests/MymeSDKTests/`. For each, the change is mechanical: swap GRDB `LocalStore`/`MutationQueue` instantiation for the new test-support helpers, update `try` → `try await` at the factory call sites.

- **`LocalStoreTests.swift`** — direct LocalStore CRUD. Add three new tests: cascade-delete (purgeItem cascades metadata), edge-orphan (purge item leaves edges dangling — preserves today's behaviour), JSON properties round-trip (every `JSONValue` case).
- **`MymeStoreTests.swift`** — reactive queries. Replace existing `waitForCondition` (`MymeStoreTests.swift:576-585`) with a new `waitForRefetch` helper that awaits 80ms (debounce + headroom).
- **`SyncEngineTests.swift`** — full sync pipeline. SyncEngine itself untouched, so the tests' assertion bodies are unchanged. Verify the three atomicity cases (§4.3).
- **`ExtensionsLocalFirstTests.swift`** — extension namespace local-first behaviour. Mechanical swap.
- **`BlobsTests.swift`** — blob namespace synced mode. The `enqueueBlobUpload` atomicity test must inject a save failure to verify "rolling back leaves neither row".
- **`ItemsTests.swift`** — synced subset only. Mechanical swap.
- **`PurgeTests.swift`**, **`MetadataTests.swift`**, **`EdgesTests.swift`** — mechanical swap; mostly storage-agnostic.

### 7.2 New test-support helpers

`Sources/MymeSDKTestSupport/SwiftDataHelpers.swift`:

```swift
@_spi(MymeSDKTestSupport) import MymeSDK
import SwiftData

public enum MymeSDKTestSupport {
    public static func makeInMemoryContainer() throws -> ModelContainer {
        try MymeModelContainer.make(path: ":memory:")
    }

    public static func makeInMemoryLocalStore() async throws -> LocalStore {
        let container = try makeInMemoryContainer()
        return await Task.detached { LocalStore(modelContainer: container) }.value
    }

    public static func makeInMemoryMutationQueue() async throws -> MutationQueue {
        let container = try makeInMemoryContainer()
        return await Task.detached { MutationQueue(modelContainer: container) }.value
    }

    /// Awaits the reactive debounce window plus headroom.
    /// Use after a write that should propagate to a reactive query.
    @MainActor
    public static func waitForRefetch(after ms: Int = 80) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }
}
```

Existing `MockTransport` and `InMemoryKeychain` (`Sources/MymeSDKTestSupport/`) are unchanged.

### 7.3 New file: `PredicateSafetyTests.swift`

`Tests/MymeSDKTests/PredicateSafetyTests.swift` — one test per rule from §6:

- `test_isEmpty_predicate_compiles_with_negation`
- `test_starts_with_works_in_predicate`
- `test_ids_contains_works_in_predicate`
- `test_localizedStandardContains_compiles`
- `test_state_raw_value_predicate_filters_correctly`
- `test_captured_value_short_circuit_pattern_filters_correctly`

Each test sets up an in-memory container with a handful of model rows, runs a fetch with the predicate, and asserts the result. SwiftData fails predicates with unsupported operators at runtime, so these tests fail loudly if a predicate ever drifts off the safe subset.

### 7.4 Test target wiring

`Package.swift` changes:
- `MymeSDKTestSupport` target gains `@_spi(MymeSDKTestSupport) import MymeSDK` capability — handled by the standard SPI mechanism without test-target-specific magic.
- No new test targets; existing `MymeSDKTests` and `CodegenCustomTypesTests` / `CodegenCompileCheckTests` unchanged in shape.

---

## 8. CloudKit readiness check

A new executable target **`cloudkit-smoke`** at `scripts/cloudkit-smoke/main.swift`. Not in CI (no entitlements on GitHub runners). Run manually before tagging. Documented in a new `Sources/MymeSDK/LocalStore/README.md`.

The executable does three things:

1. Builds a `ModelConfiguration` with `cloudKitDatabase: .private(.init(containerIdentifier: "iCloud.com.myme.sdk-dev"))` against a developer's CloudKit container.
2. Calls `try ModelContainer(for: MymeSchemaV1.self, migrationPlan: MymeMigrationPlan.self, configurations: [cfg])`. The constructor validates the schema against CloudKit constraints at init time (`#Unique`, missing inverses, `.deny` rules, missing defaults, `description` collisions all surface here).
3. Inserts one of each model (`MymeItemModel`, `MymeEdgeModel`, `MymeMetadataModel`, `PendingMutationModel`, `SyncStateModel`, `PendingBlobModel`), calls `save()`, prints `OK`, exits 0. On failure prints the validation error and exits 1.

`Package.swift` adds:
```swift
.executableTarget(
    name: "cloudkit-smoke",
    dependencies: ["MymeSDK"],
    path: "scripts/cloudkit-smoke"
)
```
…and a matching `.executable(name: "cloudkit-smoke", targets: ["cloudkit-smoke"])` product.

The PR description's test plan includes "I ran `swift run cloudkit-smoke` against my dev container and it printed `OK`" as an explicit checkbox. Manual entitlement plist + container ID provided via env var or hard-coded into the executable for the developer's local container — the developer never commits their container id back to main.

---

## 9. GRDB removal

In execution order:

1. Verify no source references — every file with `import GRDB` today is rewritten or deleted. After commit 6 (§10):
   ```
   grep -rn "import GRDB" Sources/    # must be empty
   ```
   Files that lose the import: `Client/MymeClient.swift`, `LocalStore/LocalStore.swift`, `LocalStore/LocalStoreRecords.swift`, `Reactive/MymeStore.swift`, `Reactive/ItemQuery.swift`, `Reactive/SingleItemQuery.swift`, `Reactive/EdgesQuery.swift`, `Reactive/BackrefsQuery.swift`, `Reactive/TagsQuery.swift`, `Reactive/ItemsWithMetadataQuery.swift`, `Sync/MutationQueue.swift`.
2. Delete `Sources/MymeSDK/LocalStore/LocalStoreRecords.swift` — `ItemRecord`/`EdgeRecord`/`MetadataRecord` are obsolete; `LocalStoreError` moved.
3. `Package.swift` edits:
   - Remove the `dependencies` entry for `GRDB.swift` (`Package.swift:23`).
   - Remove the `.product(name: "GRDB", package: "GRDB.swift")` from the `MymeSDK` target dependencies (`Package.swift:29`).
   - Bump `platforms` to iOS 26 / iPadOS 26 / macOS 26 / visionOS 26 / watchOS 26 / tvOS 26.
4. `swift package resolve` — auto-prunes `Package.resolved`.
5. Verify: `swift build --build-tests` (PR-tier). Locally: `swift test --parallel`.
6. Codegen freshness sanity check: `swift run codegen-wire` and `swift run codegen-domain` — no expected diff (neither generator imports GRDB).
7. CLAUDE.md edits — replace every "GRDB" mention with "SwiftData", every "DatabasePool" with "ModelContainer", every "ValueObservation" with "ModelContext.didSave + debounced refetch". Drop the WAL-mode language. Update the "Local store & sync" section, the "Reactive layer" section, the dependency list, and the platform version line.

---

## 10. Commit / PR shape

### 10.1 Commit sequence

Each commit is independently `swift build --build-tests`-clean.

1. `feat(storage): introduce SwiftData @Model schema v1`
   - Adds `LocalStore/Schema/V1/` (six `@Model` classes, `MymeSchemaV1`, mappers, predicate conventions).
   - Adds `LocalStore/Schema/MymeMigrationPlan.swift`.
   - Adds `LocalStore/MymeModelContainer.swift`.
   - Adds `Sync/MutationKind.swift`.
   - Does not touch existing GRDB code; new code is unreachable at this point.

2. `chore(deps): bump platforms to iOS 26 / macOS 26 / etc.`
   - `Package.swift` `platforms:` block.
   - Single CLAUDE.md edit to "**Platforms:** iOS 26+, macOS 26+, visionOS 26+, watchOS 26+, tvOS 26+."

3. `refactor(localstore): port LocalStore to @ModelActor`
   - Rewrites `LocalStore/LocalStore.swift` to `@ModelActor`. GRDB body deleted.
   - Adds `LocalStore/LocalStoreError.swift`. Removes `LocalStoreRecords.swift`.
   - Updates `Client/MymeClient.swift`: `local(_:)` and `synced(...)` become `async throws`; `pool` field becomes `container`.

4. `refactor(sync): port MutationQueue to @ModelActor`
   - Rewrites `Sync/MutationQueue.swift` body.
   - `PendingMutationRecord` becomes a Sendable DTO struct.
   - SyncEngine, ConnectionStateManager untouched.

5. `refactor(reactive): rebuild MymeStore queries on ModelContext.didSave`
   - Rewrites `Reactive/MymeStore.swift` and all seven query files.
   - Adds `Reactive/RefreshDebounce.swift`.
   - Public surface byte-identical.

6. `test(storage): rewrite LocalStore + MutationQueue + reactive tests for SwiftData`
   - All test files in §7.1.
   - Adds `Sources/MymeSDKTestSupport/SwiftDataHelpers.swift`.
   - Adds `Tests/MymeSDKTests/PredicateSafetyTests.swift`.

7. `chore(deps): drop GRDB`
   - `Package.swift` dependency + target-dep entries removed.
   - `Package.resolved` regenerated.
   - `grep -r "import GRDB" Sources/` empty post-commit.

8. `feat(scripts): add cloudkit-smoke executable for schema validation`
   - `scripts/cloudkit-smoke/main.swift`, `Package.swift` target/product.
   - `Sources/MymeSDK/LocalStore/README.md` documents the manual run procedure.

9. `docs: update CLAUDE.md for SwiftData store and CloudKit readiness`
   - Edits per §9 step 7.

10. `chore(release): bump to 4.0.0`
    - Single edit to whatever file holds the canonical version (verify during execution — likely a constant in `Sources/MymeSDK/Internal/` or just CHANGELOG/README).

### 10.2 PR

**Title:** `feat: migrate on-device storage to SwiftData (CloudKit-ready) — 4.0.0`

**Body:**

```
## Summary
- On-device storage (LocalStore, MutationQueue, reactive queries) ported from GRDB to SwiftData.
- Schema is CloudKit-compatible from day one (no #Unique, all defaults, explicit relationships, no .deny rules).
- CloudKit sync **unlocked**, not enabled — `cloudKitDatabase: .none` in this PR; flipping to `.automatic` is a Phase 2 PR in the Notes app.
- Public API unchanged except `MymeClient.local(_:)` / `MymeClient.synced(...)` move to `async throws` (required by `@ModelActor` off-main construction). One-line change at every call site.
- SDK platform minimums bumped to iOS 26 / iPadOS 26 / macOS 26 / visionOS 26 / watchOS 26 / tvOS 26.
- SDK 4.0.0 — major bump.
- No automatic migration for any consumer with existing local data — delete and recreate. SDK is pre-release; no external users.

## What changed
- 6 `@Model` classes in `Sources/MymeSDK/LocalStore/Schema/V1/`
- `LocalStore` and `MutationQueue` are `@ModelActor`s sharing one `ModelContainer`
- Reactive queries (`ItemQuery`, `TypedItemQuery`, `SingleItemQuery`, `EdgesQuery`, `BackrefsQuery`, `TagsQuery`, `ItemsWithMetadataQuery`) rebuilt on `ModelContext.didSave` + 50ms debounce + refetch
- GRDB removed from `Package.swift`
- New `scripts/cloudkit-smoke` executable validates the schema against the dev CloudKit container (run manually; not in CI)
- New predicate-safety conventions file + dedicated test suite

## Test plan
- [ ] `swift test --parallel` — all suites green
- [ ] `swift run codegen-wire && git diff --exit-code Sources/MymeSDK/Types/Wire/Generated/`
- [ ] `swift run codegen-domain && git diff --exit-code Sources/MymeSDK/DomainModels/Generated/`
- [ ] `swift run cloudkit-smoke` (local, against dev container) — prints "OK"
- [ ] `grep -r "import GRDB" Sources/` returns empty
- [ ] One downstream consumer (myme-notes or myme-messages) compiles cleanly against the new async factory signatures
```

---

## 11. Version bump — 4.0.0

**Source-compat surface delta:**
- `MymeClient.local(_:)` and `MymeClient.synced(...)` move from `throws` to `async throws`. Every call site needs `try await` instead of `try`. **Breaking — major bump required.**
- Platform minimums move from iOS 17+ to iOS 26+. Every consumer must update their own deployment target. **Breaking — major bump required.**
- Internal store completely rewritten. No consumer with an existing on-disk SQLite file can open it under SwiftData. Auto-deleting an unrelated database is unacceptable; consumers must be told. **Breaking — major bump required.**

**Source-compat surfaces unchanged:**
- All nine namespaces (`items`, `edges`, `metadata`, `blobs`, `extensions`, `types`, `keys`, `webhooks`, `versions`).
- All seven reactive query types — public fields, methods, factories.
- All 21 generated domain models.
- All wire types.
- `MymeStore`, `client.makeStore()`.
- `SyncEngine`, `ConnectionStateManager`, `MutationQueue` (public surface).
- All existing error subclasses.

**Recommendation: 4.0.0.** Three independent reasons each justify a major bump on their own.

---

## 12. Critical files

### Files modified
- `Sources/MymeSDK/Client/MymeClient.swift` — async factories, `pool` → `container`
- `Sources/MymeSDK/LocalStore/LocalStore.swift` — `@ModelActor`
- `Sources/MymeSDK/Sync/MutationQueue.swift` — `@ModelActor`
- `Sources/MymeSDK/Reactive/MymeStore.swift` — container-based
- `Sources/MymeSDK/Reactive/ItemQuery.swift` — didSave + debounce
- `Sources/MymeSDK/Reactive/SingleItemQuery.swift` — didSave + debounce
- `Sources/MymeSDK/Reactive/EdgesQuery.swift` — didSave + debounce
- `Sources/MymeSDK/Reactive/BackrefsQuery.swift` — didSave + debounce
- `Sources/MymeSDK/Reactive/TagsQuery.swift` — didSave + Swift aggregation
- `Sources/MymeSDK/Reactive/ItemsWithMetadataQuery.swift` — didSave + debounce
- `Package.swift` — drop GRDB, bump platforms, add `cloudkit-smoke` target/product
- `CLAUDE.md` — SwiftData rewrite of the storage and reactive sections
- All test files in §7.1

### Files added
- `Sources/MymeSDK/LocalStore/Schema/V1/MymeItemModel.swift`
- `Sources/MymeSDK/LocalStore/Schema/V1/MymeEdgeModel.swift`
- `Sources/MymeSDK/LocalStore/Schema/V1/MymeMetadataModel.swift`
- `Sources/MymeSDK/LocalStore/Schema/V1/PendingMutationModel.swift`
- `Sources/MymeSDK/LocalStore/Schema/V1/SyncStateModel.swift`
- `Sources/MymeSDK/LocalStore/Schema/V1/PendingBlobModel.swift`
- `Sources/MymeSDK/LocalStore/Schema/V1/MymeSchemaV1.swift`
- `Sources/MymeSDK/LocalStore/Schema/V1/Mappers.swift`
- `Sources/MymeSDK/LocalStore/Schema/MymeMigrationPlan.swift`
- `Sources/MymeSDK/LocalStore/Schema/PredicateConventions.swift`
- `Sources/MymeSDK/LocalStore/MymeModelContainer.swift`
- `Sources/MymeSDK/LocalStore/LocalStoreError.swift`
- `Sources/MymeSDK/LocalStore/README.md`
- `Sources/MymeSDK/Sync/MutationKind.swift`
- `Sources/MymeSDK/Reactive/RefreshDebounce.swift`
- `Sources/MymeSDKTestSupport/SwiftDataHelpers.swift`
- `Tests/MymeSDKTests/PredicateSafetyTests.swift`
- `scripts/cloudkit-smoke/main.swift`

### Files deleted
- `Sources/MymeSDK/LocalStore/LocalStoreRecords.swift`

### Files reused (unchanged)
- `Sources/MymeSDK/Sync/SyncEngine.swift` — semantically unchanged
- `Sources/MymeSDK/Sync/ConnectionStateManager.swift` — unchanged
- `Sources/MymeSDK/Namespaces/*.swift` — unchanged (call into actors via existing method signatures)
- `Sources/MymeSDK/Types/Wire/Generated/*.swift` — codegen output unchanged
- `Sources/MymeSDK/DomainModels/Generated/*.swift` — codegen output unchanged
- `Sources/MymeSDK/Inputs/*.swift`, `Errors/*.swift`, `Transport/*.swift` — unchanged
- `Sources/MymeSDK/LocalStore/UUIDv7.swift` — UUIDv7 generation unchanged
- `Sources/MymeSDKTestSupport/MockTransport.swift`, `InMemoryKeychain.swift` — unchanged

---

## 13. Verification

End-to-end checks before declaring the migration done:

1. **Build clean:** `swift build` from a clean checkout — no warnings, no errors.
2. **Test green:** `swift test --parallel` — every suite passes, including the three new atomicity tests (§4.3) and the predicate-safety suite (§7.3).
3. **Codegen freshness:**
   - `swift run codegen-wire && git diff --exit-code Sources/MymeSDK/Types/Wire/Generated/`
   - `swift run codegen-domain && git diff --exit-code Sources/MymeSDK/DomainModels/Generated/`
4. **No GRDB residue:**
   - `grep -rn "import GRDB" Sources/` returns empty
   - `grep -rn "DatabasePool\|ValueObservation\|json_each" Sources/` returns empty (all inherited concepts gone)
   - `Package.resolved` contains no GRDB entry
5. **CloudKit readiness:** `swift run cloudkit-smoke` (locally, against dev CloudKit container with entitlements) prints `OK`. Documented in `Sources/MymeSDK/LocalStore/README.md`.
6. **Downstream compile:** check at least one of myme-notes or myme-messages compiles cleanly when bumped to `MymeSDK 4.0.0` — confirms the async factory call-site changes and the platform bump don't break a real consumer.
7. **Reactive parity:** `MymeStoreTests.swift` exercises every query type's debounce-driven update path. Save → refetch → assertion within ≤80ms.
8. **Atomicity:** explicit acceptance tests for the three transaction guarantees (§4.3).

CI tier (already configured in `.github/workflows/ci.yml`):
- PR pushes run `swift build --build-tests` only — the migration commit sequence is structured so each commit is build-clean.
- Merges to `main` run the full `swift test --parallel` plus codegen freshness — the entire test rewrite must be in place before the final `chore(release): bump to 4.0.0` commit.

---

## 14. Risks / open questions for the orchestrator

1. **Vault-doc discrepancy.** `CloudKit Implementation.md` says "Five GRDB tables become @Model classes". The schema actually has six (PendingBlob is its own table, added in v4). This plan ships six. **Action for orchestrator:** correct the vault doc post-merge to read "Six".

2. **`MymeClient` version constant.** The version `3.5` lives in vault docs and likely in CHANGELOG; verify whether there's also a Swift constant during execution. If yes, bump it to `4.0.0` in the final commit.

3. **CloudKit dev container ID.** `cloudkit-smoke` needs a developer's CloudKit container ID. Recommend: read from env var `MYME_CK_CONTAINER` (default empty → executable prints "set MYME_CK_CONTAINER to a dev container id" and exits 1). Never hard-code.

4. **iOS 26 SwiftData inheritance not used in V1.** Class inheritance is iOS 26+ but the migration's six models are flat — none of them benefit from inheritance. Recording this so it doesn't get retrofitted as ceremony. If a future use case lands (e.g. typed item subclasses of `MymeItemModel`), V2 of the schema can introduce it via a `MigrationStage`.

5. **`@ModelActor` synthesised init binding.** The off-main construction rule comes from documented Apple behaviour. `Task.detached` inside the factory is the workaround. If, during implementation, we discover SwiftData on iOS 26 has changed this binding behaviour (per WWDC25 changes), the factories may not need to be `async`. Decision: ship `async throws` regardless — defensive programming + future-proof.

6. **Predicate composition limits.** The captured-value short-circuit pattern (§5.3) is the documented workaround but is verbose. iOS 26 SwiftData may have improved runtime-composable predicates. If so, V1 doesn't change but V1.1 can simplify the pattern. Tracked here so it's not forgotten.

7. **`#Index` granularity.** iOS 26 `#Index` supports compound and unique-style indexes. This plan uses compound indexes mirroring the GRDB schema. If query profiling later shows different access patterns, indexes are additive — no migration stage needed to add one in V2.

8. **Reactive debounce window — chosen 50ms.** Defensible (≈ 3 frames at 60Hz, common SSE burst horizon) but unmeasured. Recorded as a single constant `RefreshDebounce.interval` so a future profiling pass can tune it without touching seven files. If the orchestrator wants this measured before merge, that's a 1-2 hour profile-and-tweak task; default is to ship 50ms.
