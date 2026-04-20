# MymeSDK

Swift SDK for the Myme API. Equivalent to the TypeScript `@mymehq/sdk`.

## Architecture

- **SPM package**, zero external dependencies. Built from Foundation, Security, and `os`.
- **Platforms:** iOS 17+, macOS 14+, visionOS 1+, watchOS 10+, tvOS 17+.
- **Swift 6** language mode with complete strict concurrency.
- **Two products:**
  - `MymeSDK` — the client library
  - `MymeSDKTestSupport` — public test scaffolding (MockTransport, InMemoryKeychain). No semver stability across SDK minor versions; for test use only.
- **`Transport` protocol** abstracts HTTP. `URLSessionTransport` is the production impl; `MockTransport` is in test-support.
- **Namespaced API**: `client.items.create()`, `client.metadata.get()`, etc.
- **`JSONValue`** enum for arbitrary JSON (Codable, Sendable, Hashable).
- **Dates as ISO 8601 strings**, not `Date` — apps parse as needed.
- **Error hierarchy:** `open class MymeError` base with `final class` subclasses (`NotFoundError`, `UnauthorizedError`, `ForbiddenError`, `ValidationError`, `ConflictError`, `NetworkError`, `ResponseDecodingError`). Pattern-match on subclasses: `catch let error as NotFoundError`.

### Local store & sync

- **LocalStore** (`actor`) — GRDB `DatabasePool` (WAL mode) with v1 migration (items, edges, item_metadata tables + 4 indexes). Used in pure-local mode (`MymeClient.local(path:)`) and synced mode.
- **MutationQueue** (`actor`) — shares LocalStore's `DatabasePool`; v2 migration adds `pending_mutations` and `sync_state` tables. Enqueues 13 mutation kinds; `fetchAll()`/`remove(id:)`/`recordFailure(id:error:)` drain API. Persists `last_event_id` cursor for SSE reconnection.
- **ConnectionState** — `.offline`, `.connecting`, `.online`, `.syncing`. `isReachable` helper.
- **ConnectionStateManager** (`actor`) — wraps `NWPathMonitor`; bridges from `DispatchQueue` to actor via `Task { await self?.handlePath(_:) }`. Multicasts to `AsyncStream<ConnectionState>` subscribers via UUID-keyed `continuations`. `markSyncing()`/`markOnline()` for engine transitions.
- **SyncEngine** (`actor`) — observes `ConnectionStateManager.stateUpdates`; on `.connecting` opens `GET /events` SSE stream with `Last-Event-ID` cursor; applies `item.*`, `edge.*`, `metadata.changed` events to LocalStore via upsert; after stream closes, drains MutationQueue (markSyncing while replaying, markOnline when done); reconciles local-id → server-id for `createItem` replays.
- **`MymeClient.local(path:)`** — pure-local, no mutations enqueued. `MymeClient.synced(url:apiKey:storePath:connectionManager:)` — wires all four actors together; caller calls `client.syncEngine?.start()`.

### Reactive layer (@Observable, SwiftUI)

- **MymeStore** (`@Observable @MainActor`) — vended via `client.makeStore()` (returns `nil` for network-only clients). Factory for live query objects.
- **ItemQuery** — tracks `[Item]` for a `ListFilters`; GRDB `ValueObservation` on the items table with `.mainQueue` scheduler. Fields: `items`, `isLoading`, `error`. `stop()` cancels.
- **TypedItemQuery<T: MymeItem>** — like `ItemQuery` but maps records through `T.init?(from:)`, producing `[T]`.
- **SingleItemQuery** — tracks one item by id; `item` is `nil` when purged.
- **EdgesQuery** — tracks outbound edges for a `sourceId`; optional `edgeType` and `limit`.
- All query objects are `@Observable @MainActor` — pass directly to SwiftUI views; changes propagate without `ObservableObject`.

### Transport subsystems

- **Error parsing** — internal free function `parseMymeError(data:statusCode:decoder:)` in `Errors/ErrorParsing.swift`. All non-2xx paths route through it.
- **Retry / rate limits / cancellation** — `RetryPolicy` struct (bounded exponential backoff with jitter, configurable per client) and `RateLimitState` actor (tracks `X-RateLimit-*` and `Retry-After`). Task cancellation via Swift's cooperative system; `URLError(.cancelled)` translates to `CancellationError`.
- **Observability** — `MymeLogger` wraps `os.Logger` + `OSSignposter` on the stable `"sdk.myme"` subsystem with categories `transport`, `retry`, `sse`, `keychain`. `ClientConfiguration.debugLogging` flag opts in to full-body logging at `.private` privacy.
- **SSE** — `Transport.eventStream(path:query:lastEventID:)` returns `AsyncThrowingStream<SSEEvent, Error>`. `SSEParser` is WHATWG-conformant; id is sticky across events, retry attaches to the next event that fires, blank-data blocks don't dispatch. Transport only — reconnect and cursor persistence belong to the consumer.
- **Keychain** — `SecureStorage` protocol + `KeychainStorage` actor (generic-password items under `kSecAttrService = "myme.sdk"`, optional access group for app extensions). `MymeClient.fromKeychain(service:account:url:accessGroup:)` loads a stored key; `MymeClient.saveToKeychain(...)` writes it back. `InMemoryKeychain` in test-support substitutes during unit tests because SPM test binaries run unsigned.

## Build

```bash
swift build
swift test
```

Real-Keychain tests tolerate `errSecMissingEntitlement` on unsigned SPM binaries; signed host apps exercise the real path. Integration tests point at the V0 staging server via `MYME_API_URL` and `MYME_API_KEY`. Never run conformance or integration tests against production.

## CI — tiered validation

**CI is deliberately cheap on PR and thorough on main. Do not "strengthen" PR CI without a deliberate decision and update to this note.**

- **PR pushes** run `swift build --build-tests` only — compile + typecheck, no test run. Fast feedback, catches ~the same class of breakage as the full suite at roughly 30% the cost.
- **Merges to `main`** run the full suite: `swift build`, `swift test --parallel`, and both codegen freshness checks (wire types, domain models).
- **Both tiers** cache the `.build/checkouts` and `.build` directories keyed on `Package.resolved` + source hashes, so iterative source-only changes hit a warm cache.

**Why it's structured this way.** macOS runners bill at 10x Ubuntu. Running the full suite on every PR push was the single largest CI cost driver across the org (~$5/mo from this repo alone). The project is pre-release with no auto-deploy — main breakages are a "fix before tagging" signal, not a user-facing incident. The trade-off was made deliberately; full rationale lives in `~/aic-vault/Projects/myme-A1ZB0/Artifacts/32-state-of-play/CI Actions Review.md`.

**When to revisit.** If this SDK ships to the App Store or picks up external consumers, the PR/main split needs to be re-evaluated. The tradeoff is a shipping decision, not a calendar one.

**Local before pushing.** Run `swift test` locally before opening a PR or after a main-breaking change. CI on main will catch it, but pushing a broken main wastes minutes for everyone.

## Conventions

- American English.
- Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`. Scope by area: `feat(sse):`, `fix(transport):`, `refactor(client):`, etc.
- Explicit `CodingKeys` for snake_case ↔ camelCase mapping. Wire types expose camelCase externally.
- All public types are `Sendable`. Mutable shared state is either actor-isolated or behind an `NSLock.withLock` critical section.
- No force unwraps. No `try!` outside of test scaffolding where the invariant is unreachable.
- Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest.

## Codegen — wire types

Wire types under `Sources/MymeSDK/Types/Wire/Generated/` are produced by a local Swift script from the monorepo's OpenAPI spec. Hand-edits to generated files are overwritten on the next regen — don't make them.

### Regenerate

From the repo root:

```bash
# If the monorepo's openapi.json has changed:
./scripts/sync-openapi.sh

# Otherwise (registry-only changes):
swift run codegen-wire
```

Inputs:
- Spec snapshot: `scripts/openapi.json` (vendored copy of the monorepo's spec; `sync-openapi.sh` refreshes it from `../myme/openapi.json`).
- Registry: `scripts/wire-types.json` — maps Swift type names to JSON-pointer paths into the snapshot.

Output: `Sources/MymeSDK/Types/Wire/Generated/*.swift`. Files carry a `// Code generated by codegen-wire; DO NOT EDIT.` header and are committed to the repo. Stale generated files (types removed from the registry) are pruned on every run.

### When to regenerate

- After the monorepo's `openapi.json` is bumped — run `./scripts/sync-openapi.sh` (refreshes `scripts/openapi.json` and regenerates).
- After editing `scripts/wire-types.json` (adding a type, changing a pointer, adjusting a per-field override) — `swift run codegen-wire` alone is enough.

### Why vendor the spec?

The spec lives in a separate private repo; vendoring a snapshot keeps CI self-contained (no cross-repo checkout, no shared secrets) and makes diff review of wire-type changes readable alongside the regen. `sync-openapi.sh` is the single command that updates both the snapshot and the generated output atomically — don't edit `scripts/openapi.json` by hand.

### Freshness check

CI runs `swift run codegen-wire && git diff --exit-code` against `Types/Wire/Generated/`. A failing job means the spec moved or the generator emits differently than what's committed. Resolution: regen locally, commit the delta.

### What stays hand-written

- `Sources/MymeSDK/Types/Wire/Hand/` — composite wrappers (`ItemWithMetadata`, `ItemEdgeGroup`), generic helpers (`PaginatedResult<T>`), envelopes (`ItemResponse`, `MetadataResponse`, …), and types the OpenAPI spec doesn't cover (`ItemState`, `Origin`, `FieldDefinition`, `SearchResult`).
- `Sources/MymeSDK/Conflict/ConflictStrategy.swift` — the strategy enum, `ConflictData`, `ConflictResolver`, `ConflictResult`. The wire shapes (`ConflictResponse`, `ConflictSnapshot`, `MergePolicy`, `MergePolicyStrategy`) are generated under `Types/Wire/Generated/` from the 409 response schema and the embedded `merge_policy` block.
- `Sources/MymeSDK/Inputs/` — all SDK input shapes (`CreateItemInput`, `UpdateOptions`, `ListFilters`, `CreateKeyInput`, etc.).

### Registry overrides

`scripts/wire-types.json` carries three override mechanisms:

- `numericIntFields` — global list of JSON field names that are spec'd as `number` but represent whole integers in the SDK (`version`, `schema_version`, `attempt`, `status_code`, …). Widen this list when a new such field lands.
- Per-type `fieldOverrides` — raw Swift type expressions substituted verbatim (used for map-with-enum-value cases like `type_permissions: [String: TypePermission]`).
- Per-type `enumOverrides` — reuse existing hand-written enums (`KeyRole`, `ItemState`, `Origin`, `TypePermission`, `ExtensionPermission`, `EdgePermission`) instead of emitting fresh sibling enums per occurrence.

### Troubleshooting

1. Confirm the pointer resolves: `jq -c 'getpath([...])' ../myme/openapi.json`.
2. Widen `numericIntFields` in `scripts/wire-types.json` if a field expected as `Int` came out `Double`.
3. Add a per-type `fieldOverrides` entry for local overrides.
4. Add an `enumOverrides` entry to point a string-enum field at an existing hand-written enum.

## Codegen — domain models

Typed Swift structs per Myme core type live under `Sources/MymeSDK/DomainModels/Generated/`. Each struct wraps a generic `Item` and exposes typed property accessors, a failable `init?(from:)` that validates the type string and required fields, and `toProperties()` for round-tripping into create/update calls.

All 21 active core types are generated (bookmark, entity, entity.person, entity.place, event, file, file.audio, file.image, file.video, highlight, media, media.album, media.article, media.book, media.film, media.podcast, media.series, media.song, media.tv_episode, note, task).

### Regenerate

From the repo root:

```bash
# If the monorepo's type schemas have changed:
./scripts/sync-types.sh

# Otherwise (snapshot is current):
swift run codegen-domain
```

`sync-types.sh` copies from `../myme/packages/types/core/` into `scripts/core-types/` then runs `codegen-domain`.

### Freshness check

CI runs `swift run codegen-domain && git diff --exit-code` against `Sources/MymeSDK/DomainModels/Generated/`.

### MymeItem protocol

Hand-written at `Sources/MymeSDK/DomainModels/MymeItem.swift`. Provides:
- `typeIdentifier: String` — the Myme type ID
- `item: Item` — backing generic item
- `init?(from item: Item)` — failable init
- `toProperties() -> [String: JSONValue]` — build properties dict for create/update
- Default accessors for `id`, `type`, `state`, `createdAt`, `updatedAt`, `timestamp`, `version`, `source`, `sourceId`, `origin`, `library`, `isActive`, `isTrashed`, `isArchived`

### Field conventions

- Required fields are non-optional with `?? ""` / `?? 0` / `?? false` fallback (init? already guards presence).
- Optional fields are `T?`, returning `nil` when absent.
- Enum schema fields surface as `String?` (values documented in property doc comments).
- Child type fields shadow same-named parent fields for doc comments; the type mapping is identical either way.
