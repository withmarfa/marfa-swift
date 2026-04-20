# MymeSDK

The Swift SDK for the [Myme](https://myme.so) API — a typed data layer for structured personal data.

## Requirements

- Swift 6.0+ (Xcode 16+)
- iOS 17+, macOS 14+, visionOS 1+, watchOS 10+, tvOS 17+

## Install

Add the package to your project. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mymehq/swift-sdk", from: "3.0.0"),
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

// 2. Pure-local — backed by an on-device SQLite store. No server, no API key.
let offline = try MymeClient.local(path: "/path/to/store.sqlite")
_ = try await offline.items.create(CreateItemInput(type: "core.note", properties: ["body": .string("Offline")]))

// 3. Synced — writes go local first, replay to the server when reachable.
let synced = try MymeClient.synced(url: url, apiKey: key, storePath: "/path/to/store.sqlite")
await synced.syncEngine?.start()
```

SwiftUI-ready reactive queries are available on the pure-local and synced clients via `client.makeStore()`:

```swift
@State private var store = try? MymeClient.local(path: dbPath).makeStore()

var body: some View {
    if let store, let notes = store.query(filters: ListFilters(type: "core.note")) {
        List(notes.items, id: \.id) { note in
            Text(note.properties["body"]?.stringValue ?? "")
        }
    }
}
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
