# Changelog

All notable changes to the Swift SDK are documented here.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.2.1] — 2026-04-23

Additive test-support release. Gives consumer-app test suites a
one-liner path off the file-backed `MymeClient.local(path: <uuid>)`
pattern that was crashing later tests in the same process with
`"Failed to cast model MymeSDK.MymeItemModel… to MymeItemModel"`.

### Added
- **`MymeSDKTest.makeInMemoryClient()`** — builds a pure-local
  ``MymeClient`` backed by a fresh in-memory `ModelContainer`. Drop-in
  replacement for `MymeClient.local(path: <uuid>)` in test setups.
- **Consumer-app test-setup guidance** in
  `Sources/MymeSDK/LocalStore/README.md`.

### Notes
- The most plausible root cause of the crash is XCTest host-bundle
  linkage loading two distinct `MymeSDK.MymeItemModel` class pointers
  into the same process — the persistent-store code path is where that
  ambiguity surfaces. In-memory containers sidestep the persistent
  stack entirely. No SDK runtime change was made; this is a
  test-support and docs release.
- `MymeSDKTestSupport` is explicitly non-semver-stable across SDK
  minor versions. The helper is additive and safe to adopt immediately.

## [4.2.0] — 2026-04-23

Opens the SwiftData container up for caller-controlled CloudKit
mirroring. Consumers that want iCloud sync can now build a container
with `cloudKitDatabase: .automatic(containerIdentifier: …)` and pass it
straight to `MymeClient`. The pure-local convenience path is unchanged.

### Added
- **`MymeClient.local(container:)`** — new public async factory taking a
  caller-built `ModelContainer`. This is the low-level entry point; use
  it when you need to configure the container directly (for example,
  to opt into CloudKit mirroring). `MymeClient.local(path:)` remains
  and is now a convenience that delegates to it.
- **`cloudKitDatabase:` parameter on `MymeModelContainer.make`.**
  Defaults to `.none` so existing call sites are unaffected. Pass
  `.automatic(containerIdentifier: "iCloud.…")` to turn on CloudKit
  mirroring. In-memory containers ignore the argument — mirroring
  requires a persistent store.

### Changed
- **`MymeModelContainer` is now fully public** (previously
  `@_spi(MymeSDKTestSupport) public`). Consumers need direct access to
  build containers with custom CloudKit configuration before handing
  them to `MymeClient.local(container:)`.
- **`scripts/cloudkit-smoke`** now uses the public
  `MymeModelContainer.make(path:cloudKitDatabase:)` API instead of
  reaching into SPI internals. One less demonstration of the old
  pattern to remove later.

## [4.1.0] — 2026-04-23

### Added
- **`ItemsNamespace.bulk(_:)`** — batched create/update/upsert via the
  server's `/items/bulk` endpoint. Accepts `BulkInput`
  (items + `mode: .create | .update | .upsert`, `atomic`,
  `emitEvents`); returns `BulkResult` with per-item status.
- **`ItemsNamespace.bulkAction(_:)`** — batched trash / restore /
  delete / update-timestamp against multiple item IDs. `BulkActionInput`
  (ids + `action:`, `atomic`, `emitEvents`); returns `BulkActionResult`.
- Both methods cover pure-local, synced, and offline-queued replay
  paths; integration tests cover each mode.

## [4.0.0] — 2026-04-23

On-device storage migrated from GRDB/SQLite to SwiftData with a
CloudKit-compatible schema. The reactive layer and the sync engine
keep their public shape; the factories move to `async throws`.

### Added
- **SwiftData `@Model` schema** (`Sources/MymeSDK/LocalStore/Schema/V1/`) — six models (item, edge, metadata, pending mutation, sync state, pending blob). CloudKit-compatible from day one: no `#Unique`, all properties defaulted, all relationships optional with explicit inverse on one side, no `.deny` rules, Codable enums persist via their `String` rawValue.
- **`MymeModelContainer.make(path:)`** — single construction entry point. Exposed via `@_spi(MymeSDKTestSupport)` so test targets can build in-memory containers without leaking the constructor into the public surface.
- **`MymeSDKTestSupport.MymeSDKTest`** — `makeInMemoryContainer()`, `makeInMemoryLocalStore()`, `makeInMemoryStorePair()`, `waitForRefetch(after:)` helpers so tests match the production actor-construction path (`Task.detached` off-main).
- **`PredicateConventions.swift`** — documents the SwiftData predicate-safe subset every fetch and reactive refetch sticks to. `Tests/MymeSDKTests/PredicateSafetyTests.swift` regresses every supported predicate shape so a refactor can't silently drift off it.
- **`cloudkit-smoke` executable** — manual pre-tag schema validation against a developer's CloudKit container (`MYME_CK_CONTAINER` env var). Not in CI (GitHub runners don't carry CloudKit entitlements). See `Sources/MymeSDK/LocalStore/README.md`.
- **`RefreshDebounce.interval`** — single constant (50 ms) tuning the reactive debounce window across all seven query types.

### Changed
- **Factories moved to `async throws`.** `MymeClient.local(_:)` and `MymeClient.synced(...)` construct their actors via `Task.detached` so the synthesised `@ModelActor` init doesn't bind to `@MainActor`. Every call site updates `try` → `try await`.
- **`LocalStore` and `MutationQueue` are `@ModelActor`s** sharing one `ModelContainer`. Public method signatures preserved. Wire types (`Item`, `Edge`, `Metadata`) cross actor boundaries; `@Model` instances never do (mapped via `Schema/V1/Mappers.swift`).
- **`PendingMutationRecord` is a Sendable Codable DTO** (not a GRDB `PersistableRecord`). The `SyncEngine` and the rewrite/cascade logic operate on records, not models. Shape is byte-for-byte the legacy struct.
- **Reactive queries rebuilt on `ModelContext.didSave`** + 50 ms debounce + refetch. Every query type listens via `NotificationCenter.notifications(named:)` (an async sequence — no observer-token leak), runs the refetch on `@MainActor`. Public API of the seven query types (`ItemQuery`, `TypedItemQuery`, `SingleItemQuery`, `EdgesQuery`, `BackrefsQuery`, `TagsQuery`, `ItemsWithMetadataQuery`) unchanged.
- **`TagsQuery` aggregation moved to Swift.** The legacy `SELECT … FROM json_each(tags_json)` raw SQL is replaced by a single fetch with `relationshipKeyPathsForPrefetching = [\.item]` and bucketing in Swift. Same canonical ordering (count DESC, tag ASC).
- **Three atomicity guarantees preserved as single `modelContext.save()` calls:** `enqueueBlobUpload` (blob row + mutation row), `purgeItem` (item + cascade metadata), `dropMutationsReferencingLocalId` (three fetch passes, all deletes in one commit).
- **Platform minimums bumped** to iOS 26 / macOS 26 / visionOS 26 / watchOS 26 / tvOS 26. Required for the iOS-26-era SwiftData APIs the SDK uses (`#Index`, relationship-prefetching hints).
- **`PendingBlobModel.hash` renamed to `contentHash`.** The legacy name conflicts with `Hashable.hash(into:)` and triggers an `__NSCFNumber` → `NSString` cast crash inside SwiftData's runtime metadata pipeline on save. Wire payload still serialises `hash` (in `UploadBlobPayload`); only the `@Model` property moved.
- **Predicate convention rule 1 amended.** `String.isEmpty` (and its negation) silently match every row under current SwiftData. The SDK uses explicit `prop != ""` comparisons everywhere; `PredicateConventions.swift` and the regression test reflect this.

### Removed
- **GRDB dependency.** Dropped from `Package.swift`; `import GRDB` removed from every source file.
- **`LocalStoreRecords.swift`.** `ItemRecord` / `EdgeRecord` / `MetadataRecord` are obsolete under SwiftData. `LocalStoreError` moved to its own file.
- **WAL-mode / `DatabasePool` / `ValueObservation`** — replaced by SwiftData's built-in container management and change notifications.

### Migration notes

- **No automatic migration from pre-4.0 stores.** Any on-disk store from SDK 3.x or earlier is incompatible with the new schema. Consumers must delete and recreate their stores on upgrade. The SDK is pre-release; no external users depend on automatic migration.
- **CloudKit sync is unlocked but not enabled.** `cloudKitDatabase: .none` in 4.0. Phase 2 (consumer app's iCloud sync work) flips this to `.automatic` against the app's ubiquity container. The schema is already validated for CloudKit compatibility via `cloudkit-smoke`.
- **Every namespace API is unchanged.** Items, Metadata, Extensions, Edges, Blobs, Types, Keys, Webhooks — same methods, same parameters, same return types. Only `MymeClient.local(_:)` and `MymeClient.synced(...)` need a `try await` at the call site.

[4.2.0]: https://github.com/mymehq/swift-sdk/releases/tag/4.2.0
[4.1.0]: https://github.com/mymehq/swift-sdk/releases/tag/4.1.0
[4.0.0]: https://github.com/mymehq/swift-sdk/releases/tag/4.0.0
