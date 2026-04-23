# MymeSDK

The Swift SDK for the [Myme](https://myme.so) API — a typed data layer for structured personal data.

## Requirements

- Swift 6.2+ (Xcode 26+)
- iOS 26+, macOS 26+, visionOS 26+, watchOS 26+, tvOS 26+

## Install

Add the package to your project. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mymehq/swift-sdk", from: "4.0.0"),
]
```

Or in Xcode: **File → Add Packages… → `https://github.com/mymehq/swift-sdk`**.

## Quick start

Three client modes cover the common shapes:

```swift
import MymeSDK

// 1. Remote — talks to a Myme server over HTTPS.
let client = MymeClient(url: URL(string: "https://myme.example.com")!, apiKey: "myme_k1_…")

let note = try await client.items.create(
    CreateItemInput(type: "core.note", properties: ["body": .string("Hello")])
)
print(note.id)

// 2. Pure-local — backed by an on-device SwiftData store. No server, no API key.
let offline = try await MymeClient.local(path: "/path/to/store.sqlite")
_ = try await offline.items.create(CreateItemInput(type: "core.note", properties: ["body": .string("Offline")]))

// 3. Synced — writes go local first, replay to the server when reachable.
let synced = try await MymeClient.synced(url: url, apiKey: key, storePath: "/path/to/store.sqlite")
await synced.syncEngine?.start()
```

SwiftUI-ready reactive queries are available on the pure-local and synced clients via `client.makeStore()`:

```swift
// Factories are now `async throws`; load the client before building the store.
@State private var store: MymeStore? = nil

// ...
.task {
    store = try? await MymeClient.local(path: dbPath).makeStore()
}

var body: some View {
    if let store, let notes = store.query(filters: ListFilters(type: "core.note")) {
        List(notes.items, id: \.id) { note in
            Text(note.properties["body"]?.stringValue ?? "")
        }
    }
}
```

Live `TagsQuery` (tag cloud / counts), `BackrefsQuery` (inbound edges for a batch of targets), and `ItemsWithMetadataQuery` (items paired with their metadata) are available on the same store:

```swift
let tags = store.queryTags()                                                 // [TagWithCount]
let backrefs = store.queryBackrefs(to: items.map(\.id), edgeType: "in-thread")
// backrefs.edgesByTarget["msg-1"]?.count  → reply count per message

let notes = store.queryItemsWithMetadata(filters: ListFilters(type: "core.note"))
// notes.items is [ItemWithMetadata]; updates when items or metadata change
```

Local-first batched reads:

```swift
// Aggregates tags from the local store in synced / pure-local mode; hits
// GET /metadata/tags only in remote mode.
let tags = try await client.metadata.listTags()

// One SQL query in synced/pure-local mode; bounded TaskGroup fan-out in
// remote mode (cap via ClientConfiguration.maxBackrefBatchConcurrency).
let backrefs = try await client.edges.listToTargets(
    targetIds: items.map(\.id),
    edgeType: "in-thread"
)
```

## Build and test

```bash
swift build
swift test
```

Integration tests against a running server opt in via environment variables:

```bash
MYME_API_URL=… MYME_API_KEY=… swift test
```

## Generating custom type wrappers

If your app registers its own Myme types (`myapp.booking`, `myapp.user`, …), generate typed Swift wrappers instead of hand-writing them. The generated structs look just like `CoreNote` / `CoreMediaBook` — `typeIdentifier`, typed property accessors, `init?(from:)`, `toProperties()` — with parent fields flat-inlined.

### 1. Config file at your repo root

```jsonc
// myme-codegen.json
{
  "schema": 1,
  "source": { "mode": "local", "directory": "MymeTypes" },
  "output": { "directory": "Sources/MyApp/MymeTypes/Generated", "accessLevel": "public" },
  "types": { "include": ["myapp.*"] }
}
```

Drop one `<type.id>.json` file per type under `MymeTypes/`:

```json
{
  "id": "myapp.booking",
  "parent": "core.note",
  "version": 1,
  "fields": {
    "start_at": { "type": "string", "format": "datetime" },
    "party_size": { "type": "integer" }
  },
  "required": ["start_at"]
}
```

### 2. Generate

Three entry points, pick one:

```bash
# As a SwiftPM command plugin — one shot, sandboxed:
swift package --allow-writing-to-package-directory generate-myme-custom-types

# Pull schemas from a live Myme instance first, then generate:
swift package --allow-writing-to-package-directory --allow-network-connections all \
    generate-myme-custom-types --sync

# Or invoke the executables directly (CI-friendly, no sandbox prompts):
swift run codegen-custom-types
MYME_API_URL=… MYME_API_KEY=… swift run sync-custom-types
```

The `--sync` / `sync-custom-types` path calls `GET /types`, so `MYME_API_KEY` must be an API key with the `list_types` permission. Local-mode codegen needs no credentials.

Switch the config to `"mode": "live"` (with `cacheDirectory` instead of `directory`) to let `sync-custom-types` populate the cache from `GET /types` on demand.

### 3. Use the generated types

```swift
let booking = try await client.items.create(
    CreateItemInput(
        type: MyappBooking.typeIdentifier,
        properties: [
            "start_at": .string("2026-05-01T18:00:00Z"),
            "party_size": .int(4),
            "body": .string("Dinner with J and S"),
        ]
    )
)
guard let typed = MyappBooking(from: booking) else { return }
print(typed.startAt, typed.partySize ?? 0, typed.title ?? "")
```

### 4. Keep it fresh

Commit the generated files. Add a freshness check to CI:

```yaml
- run: |
    swift run codegen-custom-types
    git diff --exit-code -- Sources/MyApp/MymeTypes/Generated
```

Core schema parents (`core.note`, `core.media.book`, …) resolve automatically — the SDK ships them as a bundled resource. `core.*` IDs are always excluded from generation regardless of your include/exclude globs, so a misconfigured glob can't clobber SDK-shipped types.

## Documentation

- Architecture, conventions, and codegen workflow: [`CLAUDE.md`](./CLAUDE.md)
- API reference (generated from OpenAPI): <https://docs.myme.so> *(once published)*
- Myme data-model specification: [Myme Reference](https://myme.so/reference) *(once published)*

## Release notes

### 4.0

**Breaking change.** On-device storage migrated from GRDB/SQLite to SwiftData with a CloudKit-compatible schema. Three axes of breaking change:

- **Factories are `async throws`.** `MymeClient.local(_:)` and `MymeClient.synced(...)` moved from `throws` to `async throws` — `@ModelActor`-isolated actor construction must run off the main actor. Every call site needs `try` → `try await`.
- **Platform minimums bumped.** iOS 26 / macOS 26 / visionOS 26 / watchOS 26 / tvOS 26.
- **No automatic migration from pre-4.0 stores.** Consumers with existing on-disk SQLite files must delete and recreate. Pre-release, no external users.

CloudKit sync is **unlocked but not enabled** in 4.0 — the schema is CloudKit-compatible (no `#Unique`, all properties defaulted, all relationships optional with explicit inverse, no `.deny` rules). Phase 2 flips `cloudKitDatabase` from `.none` to `.automatic` in the consumer app's config.

Public namespaces, reactive query types, domain models, wire types, and error hierarchy are otherwise unchanged. See [`CHANGELOG.md`](./CHANGELOG.md) for the full entry.

### 3.6

**New feature.** ``ItemsWithMetadataQuery`` — a live, observable query over items paired with their metadata. Complements the existing one-shot ``ItemsNamespace/listWithMetadata(filters:)`` for SwiftUI bindings; emits `[ItemWithMetadata]` and re-fires whenever any matching `items` row or associated `item_metadata` row changes.

```swift
let query = store.queryItemsWithMetadata(filters: .init(type: "core.note"))
ForEach(query.items, id: \.item.id) { pair in
    NoteCard(item: pair.item, tags: pair.metadata.tags)
}
```

Apps that previously subscribed to ``SyncEngine/events`` and re-ran `listWithMetadata` on every mutation can replace that plumbing with a single factory call.

### 3.0

**Breaking change.** The `SyncEngine.events` stream's `conflictAutoMerged` event payload changed from `(itemId: String)` to `(payload: ConflictAutoMergedPayload)`. The new payload carries `itemId`, `mergedItemId`, `conflictedCopyId`, `fields`, and a per-field `strategy` map.

This unblocks per-type merge policy on conflict — `keep_both_copies` fields (such as `core.note.body`) spawn a sibling item tagged `conflicted-copy` instead of being overwritten by server state. `last_writer_wins` fields keep the v2.x behaviour.

Update the single call site in your event subscriber:

```swift
// Before:
case .conflictAutoMerged(let itemId): toast("Merged \(itemId)")

// After:
case .conflictAutoMerged(let payload):
    if let copyId = payload.conflictedCopyId {
        toast("Saved as conflicted copy: \(copyId)")
    } else {
        toast("Merged \(payload.itemId)")
    }
```

Server-side merge-policy lands in monorepo `v3.3.0`; `:8602` and `:8601` Atlas instances must be on that build (or newer) for the SDK to receive `merge_policy` on 409 responses. Older servers still work — the SDK falls back to last-writer-wins per field.

## License

MIT.
