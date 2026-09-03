# LocalStore

Persistent on-device store for the SDK. Backed by SwiftData with a
CloudKit-compatible V3 schema (`MarfaSchemaV3`), with registered
V1 → V2 and V2 → V3 migrations. Two `@ModelActor`s
(`LocalStore` and `MutationQueue`) share a single `ModelContainer`
constructed via `MarfaModelContainer.make(path:cloudKitDatabase:)`.
Pass `cloudKitDatabase: .automatic(containerIdentifier: "iCloud.…")`
to mirror through CloudKit; omit it for pure-local (default `.none`).

## Schema

Eight `@Model` classes, all under `Schema/Models/`:

| Model | Purpose |
| --- | --- |
| `MarfaItemModel` | Items (`core.note`, `core.task`, …). Cascade-owns `MarfaMetadataModel`. |
| `MarfaEdgeModel` | Edges between items (string ids, no `@Relationship`). |
| `MarfaMetadataModel` | Per-item metadata (tags + extension namespaces). |
| `PendingMutationModel` | Queued server writes awaiting replay. |
| `SyncStateModel` | Key/value table for sync cursor + bookkeeping. |
| `PendingBlobModel` | Binary buffer for queued blob uploads. `data` field uses `@Attribute(.externalStorage)`. |
| `DroppedMutationModel` | Permanently-failed mutations dropped from the replay queue, retained for inspection + dismissal. |
| `CachedTypeModel` | The space's type graph as the server last described it. Ships empty; nothing writes it yet. |

CloudKit invariants (no `#Unique`, every property defaulted, every
relationship optional, no `.deny` rules, Codable enums via rawValue,
no `description` property) apply across every model. See
`PredicateConventions.swift` for the predicate-safe subset all
fetches must stick to.

## Versions, and where the model classes live

`Schema/Models/` always holds the *current* shape. Every schema version
before the current one owns frozen copies of the classes it stood for,
in `Schema/Versions/FrozenV2.swift`, and `Schema/Versions/` holds one
`VersionedSchema` per version.

The arrangement is the cheap half of a choice with two sides. A new
version has to hash differently from the old one, so one of the two must
own copies. Freezing the *new* version would mean repointing `LocalStore`,
`MutationQueue`, every reactive query and every test at a nested type on
each schema change. Freezing the *old* version leaves all of that alone.
It works because nesting is invisible to Core Data — an entity is
identified by its name and hashed from that name and its property
descriptions, with no input from where the Swift type lives — and
`SchemaMigrationTests` pins exactly that by comparing the frozen copies'
hashes against a store a shipped V2 build actually wrote.

**Nothing in a frozen namespace is ever edited.** Editing it changes what
that version hashes to, Core Data then matches no version to a real store
of that age, the stage that would have migrated it never applies, and the
device takes the fail-safe path below instead. Nothing fails at build
time and nothing fails on a fresh install.

Adding V4 means: copy the live classes into a new frozen namespace at
their current shape, point V3 at it, change the live classes, add
`MarfaSchemaV4` listing them, and append a stage.

## When a store cannot be opened

Almost always it can — an older store migrates forward. The exception is
a store whose entity shapes match no version in `MarfaMigrationPlan`, or
one recording a schema version this build does not have.

`MarfaModelContainer.open(path:cloudKitDatabase:)` answers that by moving
the store aside, never deleting it:

1. **Quarantine.** The store and everything SQLite and Core Data keep
   beside it — `-wal`, `-shm`, `-journal`, and the `.<name>_SUPPORT`
   directory holding externally-stored blob bytes — are moved into
   `<store>.quarantined-<timestamp>/`. A rename needs to know nothing
   about the file's contents, so it cannot fail for the reason the open
   failed. **If the store itself will not move, nothing is deleted** and
   `LocalStoreError.storeQuarantineFailed(_:)` is thrown.

   A *sibling* that will not move is reported in the sidecar and handled
   by what it is. A journal whose database has gone holds transactions
   nothing can replay, so it is removed rather than left beside the store
   that replaces it. **The support directory is never removed**: it holds
   the only copy of the externally-stored bytes, which for this schema is
   the payload of every queued blob upload, and the fresh store neither
   reads what is in there nor collides with it, because Core Data names
   each external file with a fresh UUID. Deleting it would reach the same
   end state as the delete-and-rebuild this path replaces.
2. **Salvage.** The quarantined store is read with SQLite directly,
   because the refusal is a model-hash check and SwiftData is the one
   component guaranteed unable to read the file. The queued mutations,
   the dead letters, the sync state and the queued blobs' descriptors go
   into `recovered-queue.json` inside the quarantine directory. This step
   is best-effort: a failure costs the summary, not the data.

   A read that stops part-way through a table is named in
   `StoreRecovery.truncatedTables` and in the sidecar. `sqlite3_step`
   answers "the table ended" and "this page is unreadable" identically,
   so a partial read is otherwise indistinguishable from a complete one,
   and the counts would be reported as totals. While that list is
   non-empty they are floors.
3. **Rebuild.** A fresh empty store is built at the original path, and it
   re-hydrates from the server on the next sync. A rebuild that fails
   throws `LocalStoreError.storeRebuildFailed(quarantineDirectory:reason:)`
   rather than the container's own error, because by then the queue has
   moved somewhere only this call knows the name of.
4. **Report.** `StoreOpenResult.recovery` describes what happened.
   `MarfaClient.storeRecovery` carries it, and a synced client also emits
   `SyncEvent.storeRecovered(_:)` once from `SyncEngine.start()`.
   **An app that means to come back to the quarantine should keep the
   path it is given**, because nothing reports it a second time: the next
   launch opens the fresh store cleanly and has nothing to say.

`recovered-queue.json` is plain JSON with a `format` field and no SDK
types in it, so a reader a version behind or ahead can still parse it.
Row keys are the SDK's property names (`payloadJson`, `attemptCount`, …)
mapped back from the store's own columns. A blob's bytes are not in it —
they are in the quarantined database, which is why that database is kept.
**Nothing removes the quarantine directory.** An app decides when it is
finished with it.

## CloudKit readiness — `cloudkit-smoke`

`cloudkit-smoke` is a manual executable (not in CI — GitHub runners
don't carry CloudKit entitlements) that validates the schema against
a real CloudKit container before tagging a release.

### What it does

1. Builds a `ModelContainer` with `cloudKitDatabase: .private(<id>)`
   against the developer's CloudKit container.
2. The constructor validates the schema at init time (`#Unique`,
   missing inverses, `.deny` rules, missing defaults, `description`
   collisions all surface here).
3. Inserts one of each `@Model` and saves — the actual
   CloudKit-mirrored write path catches subtle field-encoding
   regressions that schema validation alone misses.
4. Prints `OK` and exits 0 on success; prints the error and exits 1
   on failure.

### Run procedure

```bash
# Set your dev CloudKit container id (must match an entitlement
# you can sign with — typically your personal dev team).
export MARFA_CK_CONTAINER='iCloud.com.example.marfa-dev'

swift run cloudkit-smoke
# → OK — schema validated and one of each model inserted into iCloud.com.example.marfa-dev
```

If `MARFA_CK_CONTAINER` is unset the executable prints a usage
message and exits 1 — the container id is never hard-coded.

### When to run

- Before tagging any release that includes a schema change.
- After bumping a SwiftData / iOS minimum (a new SDK may tighten
  CloudKit constraints).
- When introducing a new V<n> schema or a `MigrationStage`.

## Consumer-app test setup

Consumer apps whose test suites spin up per-test Marfa clients should
use the in-memory helper in `MarfaSDKTestSupport` rather than a
file-backed path:

```swift
// Before — file-backed, fresh on-disk store per test.
let client = try await MarfaClient.local(
    path: NSTemporaryDirectory() + UUID().uuidString
)

// After — in-memory, drop-in.
let client = try await MarfaSDKTest.makeInMemoryClient()
```

The file-backed pattern can crash later tests in the same process
with `"Failed to cast model MarfaSDK.MarfaItemModel… to MarfaItemModel"`.
The most plausible root cause is XCTest host-bundle linkage loading
two distinct `MarfaSDK.MarfaItemModel` class pointers into the same
process (the class resolves by name but compares by pointer identity),
and the persistent-store code path is where that ambiguity surfaces.
In-memory containers sidestep the persistent stack entirely. The SDK's
own suite exercises the in-memory pattern, so the reactive-query
behavior you depend on is already covered there.
