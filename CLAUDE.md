# MarfaSDK

Swift SDK for the Marfa API. Equivalent to the TypeScript `@withmarfa/sdk`.

Docs MCP convention: when working on documented surfaces (types, edges, runtime substrates, connections, auth flows), query the docs MCP at `https://docs.marfa.so/mcp` (or use `marfa docs search "<query>"` from CLI) before re-deriving from source. Docs live **only** in `withmarfa/docs` — never author docs pages in this repo; when a change touches a public surface, open a companion `withmarfa/docs` PR and link it.

## Architecture

- **SPM package**, zero external dependencies. Built from Foundation, Security, SwiftData, and `os`.
- **Platforms:** Apple platforms only — iOS, macOS, visionOS, watchOS, tvOS. `Package.swift` is the source of truth for minimum-deployment versions.
- **Swift 6** language mode with complete strict concurrency.
- **Two products:**
  - `MarfaSDK` — the client library
  - `MarfaSDKTestSupport` — public test scaffolding (MockTransport, InMemoryKeychain, SwiftDataHelpers). No semver stability across SDK minor versions; for test use only.
- **`Transport` protocol** abstracts HTTP. `URLSessionTransport` is the production impl; `MockTransport` is in test-support.
- **Namespaced API**: `client.items.create()`, `client.metadata.get()`, `client.profile.get()`, `client.connections.install(...)`, `client.integrations.list()`, etc. The full set: `items`, `metadata`, `extensions`, `edges`, `blobs`, `types`, `keys`, `webhooks`, `profile`, `connections` (with nested `leaseTokens` and `inboundWebhooks` sub-namespaces), `integrations`, `tenants`, `admin`, `auth`.
- **`JSONValue`** enum for arbitrary JSON (Codable, Sendable, Hashable).
- **Dates as ISO 8601 strings**, not `Date` — apps parse as needed.
- **Error hierarchy:** `open class MarfaError` base with `final class` subclasses (`NotFoundError`, `UnauthorizedError`, `ForbiddenError`, `ValidationError`, `ConflictError`, `NetworkError`, `ResponseDecodingError`). Pattern-match on subclasses: `catch let error as NotFoundError`.

### Local store & sync

- **LocalStore** (`@ModelActor`) — SwiftData `ModelContainer` constructed via `MarfaModelContainer.make(path:)`. `@Model` classes live under `LocalStore/Schema/`, versioned via `MarfaMigrationPlan` (see `LocalStore/Schema/MarfaMigrationPlan.swift` for the active versions). CloudKit-compatible from day one — no `#Unique`, all properties defaulted, all relationships optional with explicit inverse, no `.deny` rules, Codable enums via rawValue. Used in pure-local mode (`MarfaClient.local(path:)`) and synced mode. **`MarfaClient.local(path:)` and `MarfaClient.synced(...)` are `async throws`** — `@ModelActor` actor construction must run off the main actor.
- **MutationQueue** (`@ModelActor`) — shares LocalStore's `ModelContainer`; cross-actor saves serialise at the SQLite layer. Enqueues one record per SDK mutation verb (each case in `MutationKind`); `fetchAll()`/`remove(id:)`/`recordFailure(id:error:)` drain API returning Sendable `PendingMutationRecord` DTOs. Persists `last_event_id` cursor for SSE reconnection. `enqueueBlobUpload`/`purgeItem`/`dropMutationsReferencingLocalId` each commit as one `modelContext.save()` — atomicity preserved from the GRDB era.
- **ConnectionState** — `.offline`, `.connecting`, `.online`, `.syncing`. `isReachable` helper.
- **ConnectionStateManager** (`actor`) — wraps `NWPathMonitor`; bridges from `DispatchQueue` to actor via `Task { await self?.handlePath(_:) }`. Multicasts to `AsyncStream<ConnectionState>` subscribers via UUID-keyed `continuations`. `markSyncing()`/`markOnline()` for engine transitions.
- **SyncEngine** (`actor`) — observes `ConnectionStateManager.stateUpdates`; on `.connecting` opens `GET /events` SSE stream with `Last-Event-ID` cursor; applies `item.*`, `edge.*`, `metadata.changed` events to LocalStore via upsert; after stream closes, drains MutationQueue (markSyncing while replaying, markOnline when done); reconciles local-id → server-id for `createItem` replays.
- **`MarfaClient.local(path:)`** — pure-local, no mutations enqueued. `MarfaClient.synced(url:apiKey:storePath:connectionManager:)` — wires all four actors together; caller calls `client.syncEngine?.start()`. Both factories are `async throws`; one-line update at every call site (`try` → `try await`).
- **Local-first reads** — `metadata.listTags()` aggregates tags by fetching metadata rows with the parent item's `stateRaw != "trashed"` and bucketing in Swift (SwiftData predicates can't reach inside the JSON `tagsData` blob). `edges.listToTargets(targetIds:edgeType:limit:)` batches inbound-edge lookup: one fetch locally with `Set.contains(targetId)`, bounded `TaskGroup` fan-out remotely (cap via `ClientConfiguration.maxBackrefBatchConcurrency`, default 8).
- **Predicate safety** — `LocalStore/Schema/PredicateConventions.swift` documents the SwiftData predicate-safe subset every fetch must stick to. `Tests/MarfaSDKTests/PredicateSafetyTests.swift` regresses every supported shape so a future predicate that compiles cleanly but crashes at runtime fails CI loudly. Key rules: predicate against `*Raw` columns not Codable enum cases; use captured-value `&&` short-circuits not runtime `Predicate<T>` composition; use `prop != ""` for empty-string filtering (`isEmpty` and `!isEmpty` both misbehave in current SwiftData).
- **CloudKit readiness** — `cloudKitDatabase` is consumer-set on `MarfaModelContainer.make(...)`; the SDK schema is CloudKit-mirrored regardless. `swift run cloudkit-smoke` validates the schema against a developer's CloudKit container — see `Sources/MarfaSDK/LocalStore/README.md`. Manual run only (no CloudKit entitlements on CI runners).

### Reactive layer (@Observable, SwiftUI)

- **MarfaStore** (`@Observable @MainActor`) — vended via `client.makeStore()` (returns `nil` for network-only clients). Factory for live query objects. Holds the shared `ModelContainer` and the `ProfileNamespace` reference used by `profileStore`.
- **ItemQuery** — tracks `[Item]` for a `ListFilters`; subscribes to `ModelContext.didSave` via `NotificationCenter.notifications(named:)`, debounces 50 ms (`Reactive/RefreshDebounce.swift`), refetches on the `@MainActor`. Fields: `items`, `isLoading`, `error`. `stop()` cancels.
- **TypedItemQuery<T: MarfaItem>** — like `ItemQuery` but maps records through `T.init?(from:)`, producing `[T]`. Used by the convenience factories `store.queryConnections(kind:state:)` (`TypedItemQuery<Connection>`) and `store.queryActivity(severity:limit:)` (`TypedItemQuery<Activity>`).
- **SingleItemQuery** — tracks one item by id; `item` is `nil` when purged.
- **EdgesQuery** — tracks outbound edges for a `sourceId`; optional `edgeType` and `limit`. Second initialiser tracks every edge of a given type tenant-wide.
- **BackrefsQuery** — tracks inbound edges for a batch of `targetIds`; `edgesByTarget: [String: [Edge]]` keyed by every requested id (unknown ids stay present with `[]`). Factory: `store.queryBackrefs(to:edgeType:limit:)`.
- **TagsQuery** — tracks `[TagWithCount]` sorted count desc, tag asc — same ordering as `metadata.listTags()` and the server. Factory: `store.queryTags()`. Aggregates in Swift over a relationship-prefetched fetch (`relationshipKeyPathsForPrefetching = [\.item]`).
- **ItemsWithMetadataQuery** — items + metadata composite. Two fetches per refresh (items, then metadata where `Set<String>.contains(itemId)`); 1:1 join in Swift.
- **PendingMutationsQuery** — tracks `[PendingMutationRecord]` from the MutationQueue (queued server writes awaiting replay). Factory: `store.queryPendingMutations()` — always returns (synced and pure-local clients both have a queue).
- **BlobUploadProgressQuery** — tracks per-blob upload progress for queued blob uploads. Factory: `store.queryBlobUploadProgress()` — returns `nil` in remote-only mode (no MutationQueue / PendingBlob row to observe).
- **FullSyncStateQuery** — tracks the running full-sync cursor + completion state. Factory: `store.queryFullSyncState()` — returns `nil` in remote-only mode.
- **DroppedMutationsQuery** — tracks `[DroppedMutationRecord]` for mutations the SyncEngine permanently failed and dropped (V2 schema). Factory: `store.queryDroppedMutations()` — returns `nil` in remote-only mode.
- **ProfileStore** (`@Observable @MainActor`) — singleton view onto the calling user's `Profile`. Constructed lazily via `store.profileStore` (returns `nil` in pure-local mode — `system.profile` is server-only). Refresh on demand via `await store.profileStore?.refresh()`; mutation methods (`update`, `uploadAvatar`, `deleteAvatar`) write the returned profile back into the store on success. No SwiftData persistence — the server is the source of truth for `system.profile`, which is a virtual type joined from the `users`/`auth_user` tables and doesn't fire `item.*` SSE events.
- All query objects are `@Observable @MainActor` — pass directly to SwiftUI views; changes propagate without `ObservableObject`. The shared listener machinery lives in `RefetchObserver` (`Reactive/MarfaStore.swift`).

### Transport subsystems

- **Error parsing** — internal free function `parseMarfaError(data:statusCode:decoder:)` in `Errors/ErrorParsing.swift`. All non-2xx paths route through it.
- **Retry / rate limits / cancellation** — `RetryPolicy` struct (bounded exponential backoff with jitter, configurable per client) and `RateLimitState` actor (tracks `X-RateLimit-*` and `Retry-After`). Task cancellation via Swift's cooperative system; `URLError(.cancelled)` translates to `CancellationError`.
- **Observability** — `MarfaLogger` wraps `os.Logger` + `OSSignposter` on the stable `"sdk.marfa"` subsystem with categories `transport`, `sse`, `sync` (plus a `disabled` sentinel for test suites). `ClientConfiguration.debugLogging` flag opts in to full-body logging at `.private` privacy.
- **SSE** — `Transport.eventStream(path:query:lastEventID:)` returns `AsyncThrowingStream<SSEEvent, Error>`. `SSEParser` is WHATWG-conformant; id is sticky across events, retry attaches to the next event that fires, blank-data blocks don't dispatch. Transport only — reconnect and cursor persistence belong to the consumer.
- **Keychain** — `SecureStorage` protocol + `KeychainStorage` actor live under `Auth/Storage/` (generic-password items under `kSecAttrService = "marfa.sdk"`, optional access group for app extensions). `MarfaClient.fromKeychain(service:account:url:accessGroup:)` loads a stored key; `MarfaClient.saveToKeychain(...)` writes it back. `InMemoryKeychain` in test-support substitutes during unit tests because SPM test binaries run unsigned.

### Auth surface (`Auth/`)

Three sibling sub-directories:

- **`Auth/Storage/`** — `SecureStorage` protocol, `KeychainStorage` actor, `KeychainError`. Same shape as before; relocated under `Auth/Storage/` to make room for the OAuth surface.
- **`Auth/Core/`** — primitives shared by every flow: `Token` (the access/refresh-token bundle), `TokenProvider` protocol with two concrete impls (`StaticTokenProvider` wraps an API key, `StoredTokenProvider` actor caches an OAuth token and refreshes against the token endpoint resolved from OIDC discovery — T-216), `PKCE` (S256 verifier/challenge/state generators built on CryptoKit), `AuthError` (final-class subclasses of `MarfaError`: `OAuthError`, `DeviceFlowError`, `PasskeyError`), and the `DeviceFlow` testability seams (`DeviceFlowHTTPClient` protocol with `URLSession` conformance, `DeviceFlowClock` protocol with `SystemDeviceFlowClock` default — both `public`, both injected into `DeviceFlow.start(...)` and `DeviceFlowHandle` for unit testing without a real network or wall-clock). Test-side fakes (`FakeDeviceFlowHTTPClient`, `ManualDeviceFlowClock`) live in `MarfaSDKTestSupport`.
- **`Auth/Flows/`** — three top-level types, mirroring the TS SDK's `MarfaAuth` + `startDeviceFlow` split: `MarfaAuth` (`@MainActor` class — Authorization Code + PKCE via an ephemeral `ASWebAuthenticationSession`; `signIn(presentationContextProvider:)` returns a `TokenProvider`; ephemeral browser session means each sign-in starts with a fresh cookie jar so `signOut(_:)` actually ends the IdP session); `DeviceFlow` (free-function `start(...)` returning a `DeviceFlowHandle` actor whose `awaitToken()` polls `/auth/device/token` per RFC 8628 — no UI, suitable for headless / TV / watch); `Passkey` (`@MainActor` enum exposing `enroll(issuer:presentationContextProvider:)` only — opens `/auth/passkey/enroll` in `ASWebAuthenticationSession` and lets the web flow run the WebAuthn ceremony. Native `ASAuthorizationController` against Better-Auth's `/auth/passkey/*` REST endpoints is intentionally not implemented: those endpoints are session-cookie-gated, not OAuth-bearer-gated, so a native client can't reach them. Passkey **sign-in** is handled by `MarfaAuth.signIn(...)` — once enrolled, the web sign-in page surfaces a "Use a passkey" button automatically).

**Internal auth contract is unified through `TokenProvider`.** The transport awaits `tokenProvider.currentToken()` for the `Authorization: Bearer …` header on every request. `ClientConfiguration.apiKey` is preserved for the existing static path (`MarfaClient(url:apiKey:)`, `MarfaClient.fromKeychain(...)`, `saveToKeychain(...)`); internally those constructors wrap the key in `StaticTokenProvider`. OAuth callers use `MarfaClient(url:tokenProvider:)` or `MarfaClient.synced(url:tokenProvider:storePath:)`. `URLSessionTransport` adds **refresh-on-401**: a single 401 response triggers `tokenProvider.invalidate()` and one retry with the freshly-minted token before surfacing as `UnauthorizedError`.

### Multipart upload helper

`Transport.uploadMultipart(method:path:fieldName:filename:data:mimeType:query:)` — RFC 7578 envelope with one file part, routed through `rawRequest` so retry, auth-refresh, and rate-limit handling all apply. Used by `ProfileNamespace.uploadAvatar(...)`. Note: `BlobsNamespace.upload(...)` POSTs raw bytes with the MIME type as Content-Type — it does not go through this helper.

### System domain models (`DomainModels/System/`)

Hand-written (codegen-domain currently scans only `core.*` types): `Connection` (typed wrapper for `system.connection` items, surfacing `kind: ConnectionKind`, `scopes`, `integrationRef`, `runtimeStatus`, etc.) and `Activity` (typed wrapper for `system.activity`, surfacing `severity: ActivitySeverity`, `summary`, `connectionId`). Both conform to `MarfaItem` so they slot into `client.items.list({type: ...})`, `typedQuery<T>()`, and the reactive `queryConnections` / `queryActivity` factories. The closed enum types `ConnectionKind` (`app | integration | tenant`) and `ActivitySeverity` (`info | warning | error | actionRequired`) are hand-written under `Types/Wire/Hand/` so apps can pattern-match without comparing raw strings.

## Build

```bash
swift build
swift test
```

Real-Keychain tests tolerate `errSecMissingEntitlement` on unsigned SPM binaries; signed host apps exercise the real path. Integration tests point at the staging server via `MARFA_API_URL` and `MARFA_API_KEY`. Never run conformance or integration tests against production.

## CI — tiered validation

**CI is deliberately cheap on PR and thorough on main. Do not "strengthen" PR CI without a deliberate decision and update to this note.**

- **PR pushes** run `swift build --build-tests` only — compile + typecheck, no test run. Fast feedback, catches ~the same class of breakage as the full suite at roughly 30% the cost.
- **Merges to `main`** run the full suite: `swift build`, `swift test --parallel`, and both codegen freshness checks (wire types, domain models).
- **Both tiers** cache the `.build/checkouts` and `.build` directories keyed on `Package.resolved` + source hashes, so iterative source-only changes hit a warm cache.

**Why it's structured this way.** macOS runners bill at 10x Ubuntu. Running the full suite on every PR push was the single largest CI cost driver across the org (~$5/mo from this repo alone). The project is pre-release with no auto-deploy — main breakages are a "fix before tagging" signal, not a user-facing incident. The trade-off was made deliberately; full rationale lives in private design notes.

**When to revisit.** If this SDK ships to the App Store or picks up external consumers, the PR/main split needs to be re-evaluated. The tradeoff is a shipping decision, not a calendar one.

**Local before pushing.** Run `swift test` locally before opening a PR or after a main-breaking change. CI on main will catch it, but pushing a broken main wastes minutes for everyone.

**Runner routing.** Both jobs read `runs-on` from the `CI_RUNNER` Actions variable, defaulting to `macos-latest`. Setting `CI_RUNNER=self-hosted` at the org or repo level routes them to a self-hosted Apple Silicon runner pool — the cost-efficient option for Swift CI during private development. Will revert to hardcoded `macos-latest` before this repo goes public.

## Conventions

- American English.
- Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`. Scope by area: `feat(sse):`, `fix(transport):`, `refactor(client):`, etc.
- Explicit `CodingKeys` for snake_case ↔ camelCase mapping. Wire types expose camelCase externally.
- All public types are `Sendable`. Mutable shared state is either actor-isolated or behind an `NSLock.withLock` critical section.
- No force unwraps. No `try!` outside of test scaffolding where the invariant is unreachable.
- Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest.

## Codegen — wire types

Wire types under `Sources/MarfaSDK/Types/Wire/Generated/` are produced by a local Swift script from the monorepo's OpenAPI spec. Hand-edits to generated files are overwritten on the next regen — don't make them.

### Regenerate

From the repo root:

```bash
# If the monorepo's openapi.json has changed:
./scripts/sync-openapi.sh

# Otherwise (registry-only changes):
swift run codegen-wire
```

Inputs:
- Spec snapshot: `scripts/openapi.json` (vendored copy of the monorepo's spec; `sync-openapi.sh` refreshes it from `../marfa/openapi.json`).
- Registry: `scripts/wire-types.json` — maps Swift type names to JSON-pointer paths into the snapshot.

Output: `Sources/MarfaSDK/Types/Wire/Generated/*.swift`. Files carry a `// Code generated by codegen-wire; DO NOT EDIT.` header and are committed to the repo. Stale generated files (types removed from the registry) are pruned on every run.

### When to regenerate

- After the monorepo's `openapi.json` is bumped — run `./scripts/sync-openapi.sh` (refreshes `scripts/openapi.json` and regenerates).
- After editing `scripts/wire-types.json` (adding a type, changing a pointer, adjusting a per-field override) — `swift run codegen-wire` alone is enough.

### Why vendor the spec?

The spec lives in a separate private repo; vendoring a snapshot keeps CI self-contained (no cross-repo checkout, no shared secrets) and makes diff review of wire-type changes readable alongside the regen. `sync-openapi.sh` is the single command that updates both the snapshot and the generated output atomically — don't edit `scripts/openapi.json` by hand.

### Freshness check

CI runs `swift run codegen-wire && git diff --exit-code` against `Types/Wire/Generated/`. A failing job means the spec moved or the generator emits differently than what's committed. Resolution: regen locally, commit the delta.

### What stays hand-written

- `Sources/MarfaSDK/Types/Wire/Hand/` — composite wrappers (`ItemWithMetadataWith`, `ItemEdgeGroup`), generic helpers (`PaginatedResult<T>`), envelopes (`ItemResponse`, `MetadataResponse`, `IntegrationsListResponse`, `LeaseTokensListResponse`, `InboundWebhooksListResponse`, …), and closed enum types the OpenAPI spec carries as plain strings (`ItemState`, `Tier`, `ConnectionKind`, `ActivitySeverity`, `FieldDefinition`, `SearchResult`).
- `Sources/MarfaSDK/Conflict/ConflictStrategy.swift` — the strategy enum, `ConflictData`, `ConflictResolver`, `ConflictResult`. The wire shapes (`ConflictResponse`, `ConflictSnapshot`, `MergePolicy`, `MergePolicyStrategy`) are generated under `Types/Wire/Generated/` from the 409 response schema and the embedded `merge_policy` block.
- `Sources/MarfaSDK/Inputs/` — all SDK input shapes (`CreateItemInput`, `UpdateOptions`, `ListFilters`, `CreateKeyInput`, etc.).

### Registry overrides

`scripts/wire-types.json` carries three override mechanisms:

- `numericIntFields` — global list of JSON field names that are spec'd as `number` but represent whole integers in the SDK (`version`, `schema_version`, `attempt`, `status_code`, …). Widen this list when a new such field lands.
- Per-type `fieldOverrides` — raw Swift type expressions substituted verbatim (used for map-with-enum-value cases like `type_permissions: [String: TypePermission]`).
- Per-type `enumOverrides` — reuse existing hand-written enums (`KeyRole`, `ItemState`, `TypePermission`, `ExtensionPermission`, `EdgePermission`, `MetadataPermission`) instead of emitting fresh sibling enums per occurrence.

### Troubleshooting

1. Confirm the pointer resolves: `jq -c 'getpath([...])' ../marfa/openapi.json`.
2. Widen `numericIntFields` in `scripts/wire-types.json` if a field expected as `Int` came out `Double`.
3. Add a per-type `fieldOverrides` entry for local overrides.
4. Add an `enumOverrides` entry to point a string-enum field at an existing hand-written enum.

## Codegen — domain models

Typed Swift structs per Marfa core type live under `Sources/MarfaSDK/DomainModels/Generated/`. Each struct wraps a generic `Item` and exposes typed property accessors, a failable `init?(from:)` that validates the type string and required fields, and `toProperties()` for round-tripping into create/update calls.

A typed Swift struct is generated for every active core type — the active set is whatever the monorepo's `packages/types/core/` ships at codegen time. The CI `codegen-freshness` job catches drift between the registry and the generated Swift surface.

### Regenerate

From the repo root:

```bash
# If the monorepo's type schemas have changed:
./scripts/sync-types.sh

# Otherwise (snapshot is current):
swift run codegen-domain
```

`sync-types.sh` copies from `../marfa/packages/types/core/` into `scripts/MarfaCodegenCore/core-types/` then runs `codegen-domain`. (The snapshot lives under `MarfaCodegenCore/` because that library bundles it as a resource for custom-type codegen parent-chain resolution; `codegen-domain` reads it from the same path.)

### Freshness check

CI runs `swift run codegen-domain && git diff --exit-code` against `Sources/MarfaSDK/DomainModels/Generated/`.

### MarfaItem protocol

Hand-written at `Sources/MarfaSDK/DomainModels/MarfaItem.swift`. Provides:
- `typeIdentifier: String` — the Marfa type ID
- `item: Item` — backing generic item
- `init?(from item: Item)` — failable init
- `toProperties() -> [String: JSONValue]` — build properties dict for create/update
- Default accessors for `id`, `type`, `state`, `createdAt`, `updatedAt`, `timestamp`, `version`, `source`, `sourceId`, `library`, `isActive`, `isTrashed`, `isArchived`

### Field conventions

- Required fields are non-optional with `?? ""` / `?? 0` / `?? false` fallback (init? already guards presence).
- Optional fields are `T?`, returning `nil` when absent.
- Enum schema fields surface as `String?` (values documented in property doc comments).
- Child type fields shadow same-named parent fields for doc comments; the type mapping is identical either way.

## Codegen — custom types

Parallel tool for **consumer apps** with their own custom Marfa types. Generates the same-shaped `MarfaItem`-conforming struct as `codegen-domain`, with inheritance flattened into one struct per type.

Ships as two executables and one SwiftPM command plugin, all products of `MarfaSDK`:

- `swift run codegen-custom-types` — reads `marfa-codegen.json`, generates Swift from local JSON schemas.
- `swift run sync-custom-types` — `GET /types` against a live Marfa instance, writes schemas to the cache directory, then generates.
- `swift package generate-marfa-custom-types` — command-plugin wrapper around both. Pass `--sync` to invoke sync first.

All three consume a single `marfa-codegen.json` at the consumer's repo root. Core schemas for parent-chain resolution (`parent: core.note`, etc.) ship bundled in the `MarfaCodegenCore` resource — consumers never vendor core types.

### Architecture

- `MarfaCodegenCore` — internal library target, Foundation-only. Contains `ConfigLoader`, `SchemaLoader`, `SchemaResolver`, `NameMapper`, `CodeEmitter`, `FileWriter`, `Generator`, `SyncRunner`, plus the bundled `core-types/` JSON resource. Not exposed as a product.
- `codegen-custom-types` — executable target at `scripts/codegen-custom-types/`. Thin arg parsing over `Generator.run()`.
- `sync-custom-types` — executable target at `scripts/sync-custom-types/`. Thin arg parsing over `SyncRunner.run()`. URLSession directly, no `MarfaSDK` runtime dep.
- `GenerateMarfaCustomTypes` — command plugin at `Plugins/GenerateMarfaCustomTypes/`. Declares `writeToPackageDirectory` and `allowNetworkConnections(.all)` permissions.
- `CodegenCustomTypesTests` — unit + golden + flow + sync tests.
- `CodegenCompileCheckTests` — a second test target whose sources ARE the pre-generated Swift files. Target fails to build if codegen output shape ever regresses.

### Input contract — `marfa-codegen.json`

```json
{
  "schema": 1,
  "source": { "mode": "local", "directory": "MarfaTypes" },
  "output": { "directory": "Sources/MyApp/MarfaTypes/Generated", "accessLevel": "public" },
  "types": { "include": ["myapp.*"], "exclude": ["myapp.internal.**"] }
}
```

Mode `"live"` replaces `directory` with `cacheDirectory` and reads `MARFA_API_URL` / `MARFA_API_KEY` from env. Unknown `schema` versions fail fast. Any `core.*` id found in the source directory is rejected — the `core.*` namespace is always out of scope regardless of include/exclude globs.

### Output shape

Mirrors `codegen-domain` output for core types (`public static let typeIdentifier`, typed property accessors, `init?(from:)`, `toProperties()`) with custom-type additions:

- `public static let typeSchemaVersion` — the schema version this struct was generated against. Consumers compare with `MarfaItem.schemaVersion` at runtime for drift detection.
- `Sendable` conformance explicit.
- Parent fields grouped under `// MARK: - Inherited from <parent.id>` sections (one per ancestor).
- Swift-keyword field names emit with backtick escaping (`` `init` ``, `` `class` ``).
- Access level toggled by `output.accessLevel` — `public` (default) or `internal`.

### Freshness check (consumer CI)

Standard pattern — consumers add to their own CI:

```yaml
- run: |
    swift run codegen-custom-types
    git diff --exit-code -- Sources/MyApp/MarfaTypes/Generated
```

### Testing model

- Unit tests cover `NameMapper`, `ConfigLoader`, `SchemaResolver`, filters, and the `Generator` flow.
- `GoldenTests` runs the full generator against `Fixtures/schemas/*.json` and byte-compares output to `Fixtures/expected/*.swift`.
- `CodegenCompileCheckTests` — pre-generated Swift in `Tests/CodegenCustomTypesTests/CompileCheck/` compiles as part of the test target; regressions fail the build.
- `SyncTests` uses an in-memory `HTTPFetcher` mock (no URLProtocol plumbing).

No live-server integration test — the MockFetcher covers the contract and keeps CI hermetic.

### Refreshing golden files after an intentional emitter change

1. Update `scripts/MarfaCodegenCore/CodeEmitter.swift`.
2. Run the generator against `Tests/CodegenCustomTypesTests/Fixtures/schemas/` into a scratch dir.
3. Copy the outputs over both `Fixtures/expected/*.swift` and `CompileCheck/*.swift`.
4. `swift test --filter CodegenCustomTypesTests` to verify.
