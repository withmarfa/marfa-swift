# LocalStore

Persistent on-device store for the SDK. Backed by SwiftData with a
CloudKit-compatible v2 schema (`MarfaSchemaV2`) with a registered
V1 → V2 migration. Two `@ModelActor`s
(`LocalStore` and `MutationQueue`) share a single `ModelContainer`
constructed via `MarfaModelContainer.make(path:cloudKitDatabase:)`.
Pass `cloudKitDatabase: .automatic(containerIdentifier: "iCloud.…")`
to mirror through CloudKit; omit it for pure-local (default `.none`).

## Schema

Seven `@Model` classes (six under `Schema/V1/`, plus
`DroppedMutationModel` added in `Schema/V2/`):

| Model | Purpose |
| --- | --- |
| `MarfaItemModel` | Items (`core.note`, `core.task`, …). Cascade-owns `MarfaMetadataModel`. |
| `MarfaEdgeModel` | Edges between items (string ids, no `@Relationship`). |
| `MarfaMetadataModel` | Per-item metadata (tags + extension namespaces). |
| `PendingMutationModel` | Queued server writes awaiting replay. |
| `SyncStateModel` | Key/value table for sync cursor + bookkeeping. |
| `PendingBlobModel` | Binary buffer for queued blob uploads. `data` field uses `@Attribute(.externalStorage)`. |
| `DroppedMutationModel` | Permanently-failed mutations dropped from the replay queue, retained for inspection + dismissal. |

CloudKit invariants (no `#Unique`, every property defaulted, every
relationship optional, no `.deny` rules, Codable enums via rawValue,
no `description` property) apply across every model. See
`PredicateConventions.swift` for the predicate-safe subset all
fetches must stick to.

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
