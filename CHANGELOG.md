# Changelog

All notable changes to the Swift SDK are documented here.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [5.2.0] — 2026-04-27

Dropped-mutation recovery release. Second half of the
checkpoint+recovery rollout that began with 5.1.0. Adds the persisted
log apps need to surface "what couldn't be saved" — closes the v3.2.0
"toast then nothing" hole.

Carries the SDK's first SwiftData schema migration: a lightweight V1 →
V2 stage purely additive (one new `@Model`). Apps that opened a V1
store under 5.0.x or 5.1.x land on V2 on first open after upgrading;
existing rows survive untouched.

### Added

- **`DroppedMutationModel` (V2 schema, `@Model`).** Persistent record
  of every mutation the engine drops permanently. Carries the
  original payload, the dropping `MymeError` shape (status / code /
  message capped at 1024 chars / details JSON), the original
  enqueue timestamp, and the drop timestamp.
- **`DroppedMutationRecord` Sendable DTO + `MutationQueue.fetchDropped()`.**
  Returns every dropped row, newest first.
- **`MymeStore.queryDroppedMutations()`** vending
  `DroppedMutationsQuery` (`@Observable @MainActor`). Refreshes on
  the same `ModelContext.didSave` + 50 ms debounce as every other
  reactive query. Returns `nil` for clients without a sync engine.
- **Dismissal APIs on `MymeStore`** (forwarding to `MutationQueue`):
  - `store.dismissDropped(id:)` — single row.
  - `store.dismissDroppedOlderThan(_:)` — strictly less-than the
    cutoff. Lets long-running apps clear stale rows without the SDK
    committing to an opinionated retention default.
  - `store.dismissAllDropped()` — clears the table.
- **First on-disk migration test in the repo.**
  `SchemaMigrationTests` writes a V1 store, closes the container,
  reopens via `MymeModelContainer.make` (which uses the V2
  migration plan), and asserts: existing rows survive,
  `DroppedMutationModel` queryable + empty, post-migration inserts
  succeed.

### Changed

- **`SyncEngine` drop sites use `recordDropped(record:droppedAt:error:)`
  atomically.** The dropped-row insert and the live-row remove now
  commit in a single `modelContext.save()` rather than two separate
  ops, eliminating the window where a crash mid-sequence could
  leave the live row gone but the log row missing.
- **`MutationQueue.dropMutationsReferencingLocalId(_:droppedAt:error:)`**
  signature now takes the cascade timestamp + error. The cascade
  also persists every orphan as a `DroppedMutationModel` row in the
  same save.

### Notes

- Lightweight V1 → V2 migration shipped via
  `MigrationStage.lightweight(fromVersion:toVersion:)`. No data
  reshape, just a new table.
- The drop-and-recreate fallback in `MymeModelContainer.make` is
  unchanged. It's conservative-aggressive — any future migration
  failure (corrupt store, broken custom stage) will also clear the
  `DroppedMutationModel` rows. The dropped log is therefore
  best-effort across migration boundaries; treat it as a recovery
  aid, not a durable audit trail.
- No retry API in this delivery. A future `retryDropped(id:)` slots
  in cleanly later (decode the payload back into the original
  mutation kind, re-enqueue, drop the log row).

## [5.1.0] — 2026-04-27

Full-sync-state checkpoint release. First half of a two-PR rollout
(recovery surface lands as 5.2.0); ships a discrete state apps can
render against to answer "is the local store currently caught up?".
Additive only — no schema bump, no wire breaks.

### Added

- **`FullSyncState` enum.** `.notYetSynced` / `.syncing` / `.synced(at:)` /
  `.failed(at:error:)`. Composes the engine's drain progress and the
  most recent cycle's outcome into a single value. Not `Equatable` —
  the `.failed` case carries an `Error`.
- **`SyncEngine.fullSyncState`** point-read accessor for tests and
  headless callers; `SyncEngine.lastCleanDrainAt` exposes the persisted
  timestamp directly. Both are `async` getters on the actor.
- **`MymeStore.queryFullSyncState()`** vending `FullSyncStateQuery`
  (`@Observable @MainActor`). Seeds initial state from the persisted
  `last_clean_drain_at` timestamp, then folds `SyncEngine.events`
  (`.syncing` / `.synced(at:)` / `.failed(error:)`) into the discrete
  state machine. Returns `nil` for network-only / pure-local clients
  without a sync engine.
- **`SyncEvent.syncing` case.** Emitted from inside
  `replayMutations()` once per cycle, after the engine has confirmed
  there is at least one record to replay (so an empty queue does not
  flap consumers through `.syncing`). Closes the "we are now syncing"
  signal hole that previously required a separate
  `ConnectionStateManager.stateUpdates` subscription.
- **New `last_clean_drain_at` key in `SyncStateModel`.** Stamped by
  `SyncEngine` in both clean-completion paths of `replayMutations()`
  (early-return on empty queue, post-loop success). Distinct from
  `last_full_sync_at` which only stamps on `performInitialSync()`
  completion — apps that want "have we ever pulled from the server?"
  read the existing accessor; apps that want "is the local store
  currently caught up?" read the new one or subscribe via the
  reactive query.

### Notes

- No schema migration required — the new key is just another row in
  the existing `SyncStateModel` table.
- The `Notes` app's `performInitialSync` gating Backlog item is now
  unblocked.

## [5.0.1] — 2026-04-26

CI hygiene release.

### Changed

- `MockTransport` hardened against unexpected request paths during
  full-validate runs.
- `full-validate` workflow on `main` no longer blocks on the codegen
  freshness check when no codegen inputs changed.

## [5.0.0] — 2026-04-25

TSC42 rollout. Breaking schema change on the local store; pre-5.0
stores cannot be lightweight-migrated to this version. The SDK had
no real users at this point and the recovery is drop-and-recreate
(`MymeModelContainer.make` deletes and reopens on schema mismatch).

### Changed

- **`Item.library: Bool` → `Item.tier: String`.** Tier-axis rename
  with a new persisted field shape (`feed` / `vault`).
- **New `SchemaVersionMismatchError` (`MymeError` subclass).** Surfaces
  server-side schema-mismatch responses; `isPermanent` returns `true`
  so the engine drops mutations rejected for schema drift.
- **Reserved-root type-id validator.** `core.*` and `sys.*` are now
  validated server-side; client paths reject ahead-of-time.

## [4.5.0] — 2026-04-24

Sync-maturity release. Three post-Phase-2 investments from the
swift-platform review — proactive drain on enqueue, per-mutation
status observable, per-blob upload progress observable. Additive only,
no breaking changes. Closes out the review's two Tier-2 backlog items
for the SDK plus one new recommendation.

### Added

- **Proactive mutation drain on enqueue.** `SyncEngine` now triggers
  `replayMutations()` within 150 ms of an enqueue when the engine is
  `.online`, coalescing bursts via a debounced listener on
  `MutationQueue.drainRequests`. Previously replay only fired on SSE
  stream close — a device that's online but idle would hold pending
  writes until the next stream reconnect. `.offline`, `.connecting`,
  and `.syncing` gates short out (queue sits silently / SSE-close
  path picks up / drain already in flight respectively). Configurable
  via new `SyncEngine.init(drainDebounceInterval:)` parameter
  (default `.milliseconds(150)`).
- **`PendingMutationsQuery` reactive surface.** Vended via
  `store.queryPendingMutations()`. Observable `mutations:
  [PendingMutationSummary]` with per-mutation `status: PendingMutationStatus`
  (`.pending` / `.inFlight` / `.retrying(attemptCount:lastError:)`).
  Refreshes on the same `ModelContext.didSave` + 50 ms debounce as
  every other reactive query. Lets consumer apps render richer
  offline UX than the coarse `hasPendingMutations: Bool` allowed —
  per-item badges, queue visualisations, retry banners.
  `hasPendingMutations` is unchanged for consumer-app compatibility.
- **`BlobUploadProgressQuery` reactive surface.** Vended via
  `store.queryBlobUploadProgress()` (returns `nil` for network-only
  clients). Tracks per-hash `BlobUploadProgress` entries with `state:
  BlobUploadState` (`.pending` / `.uploading(bytesUploaded:totalBytes:)`
  / `.completed` / `.failed(MymeError)`). Entries are evicted from
  the `uploads` dict on `blobUploadCompleted` — apps wanting a
  "recently completed" fade layer it on top. Replaces the hand-rolled
  `AttachmentUploadTracker` pattern in consumer apps.
- **Four new `SyncEvent` cases.** `blobUploadStarted`,
  `blobUploadProgress`, `blobUploadCompleted`, `blobUploadFailed`.
  Emitted by the `.uploadBlob` mutation-replay branch.
  `BlobUploadProgressQuery` subscribes to the shared `SyncEngine.events`
  stream — no parallel event surface.
- **`Transport.rawUpload(method:path:body:contentType:query:onBytesSent:)`.**
  Per-request `URLSessionTaskDelegate` forwards `didSendBodyData`
  to the caller. `URLSessionTransport` and the test-support
  `MockTransport` both implement; third-party transports get a
  default that routes through `rawRequest` and drops progress.
- **`BlobsNamespace.upload(data:mimeType:onProgress:)` optional
  callback.** Direct-mode callers (network-only `MymeClient`) can
  observe progress without subscribing to the reactive layer. Synced
  mode ignores the callback (uploads are queued; use the reactive
  query for progress). Unchanged default call signature.

### Schema

- **`stateRaw: String` added to `PendingMutationModel`.** Additive
  SwiftData property with a `"pending"` default. Lightweight
  migration handles existing rows transparently — no new
  `SchemaMigrationPlan` stage. Stored as `PendingMutationState.rawValue`
  (`pending` / `inFlight`). CloudKit-compatible: defaulted, no
  `#Unique`, not a relationship.

### Fixed / audited

- **`LocalModeUnsupportedError` guard on `TypesNamespace.get()` —
  verified present.** Follow-up to the vault backlog suspicion that
  4.2.2's guard covered `list()` but not `get()`. Audit confirmed all
  five methods (`list`, `get`, `register`, `update`, `delete`) call
  `ensureRemote` correctly. Any consumer-app retry storm in local
  mode is app-side (the app should negative-cache
  `LocalModeUnsupportedError` rather than re-calling on every
  request); no SDK change shipped.

### Notes

- Blob progress resets to `0` on transient-retry after a failure —
  the server has no resumable-chunk support, so each retry re-emits
  `blobUploadStarted` for the same hash and `uploads[hash]` is
  overwritten with a fresh `.uploading(0, total)`.
- The drain listener uses the `ConnectionStateManager.state`
  accessor (already public). No new public surface on
  `ConnectionStateManager`.
- The codegen tooling (`codegen-wire`, `codegen-domain`) was not
  touched.

## [4.4.0] — 2026-04-24

Bulk-edges end-to-end + client-side chunking convenience for both items
and edges. The 4.3.0 tag is reserved for the parked
`feat/sync-observability-4.3.0` branch; this release skips over it.

### Added
- **`edges.bulk(_:)`** — creates or upserts many edges in a single
  `POST /edges/bulk` call. Mirrors ``ItemsNamespace/bulk(_:)``: shared
  `BulkMode` / `BulkOutcome` enums, same `atomic` / `emit_events`
  switches, 5000-edge server cap. Idempotency key is
  `(source_id, target_id, edge_type)`; `createOnly` surfaces duplicates
  as ``BulkOutcome/skipped`` with reason `"duplicate_edge"`; `upsert`
  replaces properties in place.
  - Pure-local: iterates through ``LocalStore/createEdge`` with
    best-effort outcomes (no upsert path — local edges have no
    cross-client properties contract). Errors land as
    ``BulkOutcome/errored``.
  - Synced: local iteration for immediate feedback plus an enqueued
    ``MutationKind/bulkEdges`` record; replay re-issues the identical
    call on reconnect.
  - Network-only: straight round-trip.
- **`items.bulkAll(_:batchSize:mode:atomic:emitEvents:progressHandler:)`**
  — chunked iteration over ``ItemsNamespace/bulk(_:)``. Aggregates
  per-item results and counts across batches, preserves absolute
  indices. Default `batchSize: 500`, clamped to 5000. Optional
  `progressHandler` fires once per completed batch with
  `(itemsCompleted, itemsTotal)`. Non-atomic batches synthesize one
  ``BulkOutcome/errored`` entry per item in a failed slice so counts
  stay consistent with the input size; `atomic: true` throws on the
  first failing batch.
- **`edges.bulkAll(_:batchSize:mode:atomic:emitEvents:progressHandler:)`**
  — same shape as `items.bulkAll`, same clamping, same non-atomic
  per-slice synthesis. Wraps `edges.bulk`.

### Wire types
- `BulkEdgeInput`, `BulkEdgeInputItem`, `BulkEdgeResult`,
  `BulkEdgeResultEntry` in `Inputs/BulkEdgeInputs.swift`. Reuses the
  existing `BulkMode`, `BulkOutcome`, `BulkResultError`,
  `BulkResultCounts` types.

### Notes
- `MutationKind.bulkEdges` appended to the enum — additive-only as
  required for CloudKit-mirrored stores.
- `openapi.json` snapshot resynced from the monorepo at
  `@mymehq/sdk` 3.8.0.
- Cross-batch atomicity does NOT hold for the `bulkAll` helpers.
  Each batch's `atomic` guarantee stops at its own transaction —
  callers relying on strict all-or-nothing semantics for a run larger
  than one batch need to reconcile failures out-of-band.

## [4.2.2] — 2026-04-24

Defensive bug fix. `TypesNamespace`, `KeysNamespace`, and
`WebhooksNamespace` previously hit the transport unconditionally. On a
pure-local client (`MymeClient.local(path:)` or the iCloud-mode
`local(container:)`) the transport is bound to a placeholder
`local://offline` URL, so every call exploded with an opaque
`URLError` instead of a typed SDK error. Only `types.get(id:)` was
biting in production today — Notes-style consumers that look up custom
type schemas in local mode — but `keys` and `webhooks` had the same
shape and would have failed the moment a consumer touched them.

### Fixed
- **`types`, `keys`, `webhooks` now throw `LocalModeUnsupportedError`
  on pure-local clients** instead of leaking a `URLError` from the
  underlying `URLSession`. Matches the existing `BlobsNamespace`
  guard. Network and synced clients are unchanged.

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
