# LocalStore

Persistent on-device store for the SDK. Backed by SwiftData with a
CloudKit-compatible v1 schema (`MymeSchemaV1`). Two `@ModelActor`s
(`LocalStore` and `MutationQueue`) share a single `ModelContainer`
constructed via `MymeModelContainer.make(path:cloudKitDatabase:)`.
Pass `cloudKitDatabase: .automatic(containerIdentifier: "iCloud.…")`
to mirror through CloudKit; omit it for pure-local (default `.none`).

## Schema

Six `@Model` classes under `Schema/V1/`:

| Model | Purpose |
| --- | --- |
| `MymeItemModel` | Items (`core.note`, `core.task`, …). Cascade-owns `MymeMetadataModel`. |
| `MymeEdgeModel` | Edges between items (string ids, no `@Relationship`). |
| `MymeMetadataModel` | Per-item metadata (tags + extension namespaces). |
| `PendingMutationModel` | Queued server writes awaiting replay. |
| `SyncStateModel` | Key/value table for sync cursor + bookkeeping. |
| `PendingBlobModel` | Binary buffer for queued blob uploads. `data` field uses `@Attribute(.externalStorage)`. |

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
export MYME_CK_CONTAINER='iCloud.com.example.myme-dev'

swift run cloudkit-smoke
# → OK — schema validated and one of each model inserted into iCloud.com.example.myme-dev
```

If `MYME_CK_CONTAINER` is unset the executable prints a usage
message and exits 1 — the container id is never hard-coded.

### When to run

- Before tagging any release that includes a schema change.
- After bumping a SwiftData / iOS minimum (a new SDK may tighten
  CloudKit constraints).
- When introducing a new V<n> schema or a `MigrationStage`.
