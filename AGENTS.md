# MarfaSDK

Swift SDK for the Marfa API. Equivalent to the TypeScript `@withmarfa/sdk`.

Before re-deriving documented surfaces (types, edges, runtime substrates, connections, auth flows) from source, query the docs MCP at `https://docs.marfa.so/mcp` (or `marfa docs search "<query>"` from CLI). Docs live **only** in `withmarfa/docs` — never author docs pages here; when a change touches a public surface, open a companion `withmarfa/docs` PR and link it.

## Architecture

- **SPM package**, zero external dependencies. Built from Foundation, Security, SwiftData, and `os`.
- **Apple platforms only:** iOS, macOS, visionOS, watchOS, tvOS. `Package.swift` is the source of truth for minimum-deployment versions.
- **Swift 6** language mode, complete strict concurrency.
- **Two products:** `MarfaSDK` (client library) and `MarfaSDKTestSupport` (public test scaffolding: MockTransport, InMemoryKeychain, SwiftDataHelpers). Test support has no semver stability across SDK minor versions.
- **`Transport` protocol** abstracts HTTP. `URLSessionTransport` is the production impl; `MockTransport` is in test-support.
- **Namespaced API:** `client.items.create()`, `client.metadata.get()`, etc. Full set: `items`, `metadata`, `extensions`, `edges`, `blobs`, `types`, `keys`, `webhooks`, `profile`, `connections` (with nested `leaseTokens` and `inboundWebhooks`), `integrations`, `tenants`, `admin`, `auth`.
- **`JSONValue`** enum for arbitrary JSON (Codable, Sendable, Hashable).
- **Dates as ISO 8601 strings**, not `Date` — apps parse as needed.
- **Error hierarchy:** `open class MarfaError` base with `final class` subclasses (`NotFoundError`, `UnauthorizedError`, `ForbiddenError`, `ValidationError`, `ConflictError`, `NetworkError`, `ResponseDecodingError`). Pattern-match on subclasses: `catch let error as NotFoundError`.

### Local store & sync

Four actors wire together for synced mode; `MarfaClient.local(path:)` runs pure-local (no mutations enqueued).

- **LocalStore** (`@ModelActor`) — SwiftData `ModelContainer` from `MarfaModelContainer.make(path:)`. `@Model` classes under `LocalStore/Schema/`, versioned via `MarfaMigrationPlan`. CloudKit-compatible from day one: no `#Unique`, all properties defaulted, all relationships optional with explicit inverse, no `.deny` rules, Codable enums via rawValue.
- **MutationQueue** (`@ModelActor`) — shares LocalStore's `ModelContainer`; cross-actor saves serialize at the SQLite layer. One record per SDK mutation verb (`MutationKind`); `fetchAll()`/`remove(id:)`/`recordFailure(id:error:)` drain API returning Sendable `PendingMutationRecord` DTOs. Persists `last_event_id` cursor for SSE reconnection. `enqueueBlobUpload`/`purgeItem`/`dropMutationsReferencingLocalId` each commit as one `modelContext.save()`.
- **ConnectionState** — `.offline`, `.connecting`, `.online`, `.syncing`, plus `isReachable`.
- **ConnectionStateManager** (`actor`) — wraps `NWPathMonitor`; bridges `DispatchQueue` to actor via `Task { await self?.handlePath(_:) }`. Multicasts to `AsyncStream<ConnectionState>` subscribers via UUID-keyed `continuations`. `markSyncing()`/`markOnline()` for engine transitions.
- **SyncEngine** (`actor`) — observes `ConnectionStateManager.stateUpdates`; on `.connecting` opens `GET /events` SSE with `Last-Event-ID` cursor; applies `item.*`, `edge.*`, `metadata.changed` to LocalStore via upsert; after stream closes, drains MutationQueue (markSyncing while replaying, markOnline when done); reconciles local-id → server-id for `createItem` replays.

Both factories (`MarfaClient.local(path:)`, `MarfaClient.synced(url:apiKey:storePath:connectionManager:)`) are **`async throws`** — `@ModelActor` construction must run off the main actor, so every call site is `try await`. For synced clients the caller invokes `client.syncEngine?.start()`.

- **Local-first reads** — `metadata.listTags()` aggregates tags by fetching metadata rows where the parent item's `stateRaw != "trashed"` and bucketing in Swift (SwiftData predicates can't reach inside the JSON `tagsData` blob). `edges.listToTargets(targetIds:edgeType:limit:)` batches inbound-edge lookup: one local fetch with `Set.contains(targetId)`, bounded `TaskGroup` fan-out remotely (cap via `ClientConfiguration.maxBackrefBatchConcurrency`, default 8).
- **Predicate safety** — `LocalStore/Schema/PredicateConventions.swift` documents the predicate-safe subset every fetch must use; `Tests/MarfaSDKTests/PredicateSafetyTests.swift` regresses every supported shape so a predicate that compiles but crashes at runtime fails CI. Key rules: predicate against `*Raw` columns not Codable enum cases; use captured-value `&&` short-circuits not runtime `Predicate<T>` composition; use `prop != ""` for empty-string filtering (`isEmpty`/`!isEmpty` both misbehave in current SwiftData).
- **CloudKit readiness** — `cloudKitDatabase` is consumer-set on `MarfaModelContainer.make(...)`; the schema is CloudKit-mirrored regardless. `swift run cloudkit-smoke` validates the schema against a developer's CloudKit container (see `Sources/MarfaSDK/LocalStore/README.md`). Manual run only — no CloudKit entitlements on CI runners.

### Reactive layer (@Observable, SwiftUI)

All query objects are `@Observable @MainActor` — pass directly to SwiftUI views; changes propagate without `ObservableObject`. Shared listener machinery lives in `RefetchObserver` (`Reactive/MarfaStore.swift`).

- **MarfaStore** (`@Observable @MainActor`) — vended via `client.makeStore()` (`nil` for network-only clients). Factory for live query objects; holds the shared `ModelContainer` and the `ProfileNamespace` reference.
- **ItemQuery** — tracks `[Item]` for a `ListFilters`; subscribes to `ModelContext.didSave`, debounces 50 ms (`Reactive/RefreshDebounce.swift`), refetches on the `@MainActor`. Fields: `items`, `isLoading`, `error`; `stop()` cancels.
- **TypedItemQuery<T: MarfaItem>** — like `ItemQuery` but maps records through `T.init?(from:)`. Backs `store.queryConnections(kind:state:)` (`TypedItemQuery<Connection>`) and `store.queryActivity(severity:limit:)` (`TypedItemQuery<Activity>`).
- **SingleItemQuery** — one item by id; `item` is `nil` when purged.
- **EdgesQuery** — outbound edges for a `sourceId`; optional `edgeType` and `limit`. Second initializer tracks every edge of a type tenant-wide.
- **BackrefsQuery** — inbound edges for a batch of `targetIds`; `edgesByTarget: [String: [Edge]]` keyed by every requested id (unknown ids stay present with `[]`). Factory: `store.queryBackrefs(to:edgeType:limit:)`.
- **TagsQuery** — `[TagWithCount]` sorted count desc, tag asc (same ordering as `metadata.listTags()` and the server). Factory: `store.queryTags()`. Aggregates in Swift over a relationship-prefetched fetch.
- **ItemsWithMetadataQuery** — items + metadata composite. Two fetches per refresh, 1:1 join in Swift.
- **PendingMutationsQuery** — `[PendingMutationRecord]` from the MutationQueue (queued writes awaiting replay). Factory: `store.queryPendingMutations()` — always returns; synced and pure-local clients both have a queue.
- **BlobUploadProgressQuery** — per-blob upload progress for queued uploads. Factory: `store.queryBlobUploadProgress()` — `nil` in remote-only mode.
- **FullSyncStateQuery** — running full-sync cursor + completion state. Factory: `store.queryFullSyncState()` — `nil` in remote-only mode.
- **DroppedMutationsQuery** — `[DroppedMutationRecord]` for mutations the SyncEngine permanently failed and dropped (V2 schema). Factory: `store.queryDroppedMutations()` — `nil` in remote-only mode.
- **ProfileStore** (`@Observable @MainActor`) — singleton view onto the calling user's `Profile`, built lazily via `store.profileStore` (`nil` in pure-local mode — `system.profile` is server-only). `refresh()` on demand; `update`/`uploadAvatar`/`deleteAvatar` write the returned profile back on success. No SwiftData persistence: the server owns `system.profile`, a virtual type joined from `users`/`auth_user` that fires no `item.*` SSE events.

### Transport subsystems

- **Error parsing** — internal `parseMarfaError(data:statusCode:decoder:)` in `Errors/ErrorParsing.swift`. All non-2xx paths route through it.
- **Retry / rate limits / cancellation** — `RetryPolicy` struct (bounded exponential backoff with jitter, configurable per client) and `RateLimitState` actor (tracks `X-RateLimit-*` and `Retry-After`). `URLError(.cancelled)` translates to `CancellationError`.
- **Observability** — `MarfaLogger` wraps `os.Logger` + `OSSignposter` on the `"sdk.marfa"` subsystem with categories `transport`, `sse`, `sync` (plus a `disabled` sentinel for tests). `ClientConfiguration.debugLogging` opts in to full-body logging at `.private` privacy.
- **SSE** — `Transport.eventStream(path:query:lastEventID:)` returns `AsyncThrowingStream<SSEEvent, Error>`. `SSEParser` is WHATWG-conformant; id is sticky across events, retry attaches to the next event, blank-data blocks don't dispatch. Transport only — reconnect and cursor persistence belong to the consumer.
- **Keychain** — `SecureStorage` protocol + `KeychainStorage` actor under `Auth/Storage/` (generic-password items under `kSecAttrService = "marfa.sdk"`, optional access group for app extensions). `MarfaClient.fromKeychain(...)` loads a stored key; `MarfaClient.saveToKeychain(...)` writes it back. `InMemoryKeychain` substitutes in unit tests because SPM test binaries run unsigned.

### Auth surface (`Auth/`)

Three sibling sub-directories:

- **`Auth/Storage/`** — `SecureStorage` protocol, `KeychainStorage` actor, `KeychainError`.
- **`Auth/Core/`** — primitives shared by every flow: `Token` (access/refresh bundle), `TokenProvider` protocol with two impls (`StaticTokenProvider` wraps an API key; `StoredTokenProvider` actor caches an OAuth token and refreshes against the token endpoint from OIDC discovery), `PKCE` (S256 generators on CryptoKit), `AuthError` subclasses (`OAuthError`, `DeviceFlowError`, `PasskeyError`), and the `DeviceFlow` testability seams (`DeviceFlowHTTPClient` and `DeviceFlowClock` protocols, both `public`, both injected for unit testing without network or wall-clock). Test fakes (`FakeDeviceFlowHTTPClient`, `ManualDeviceFlowClock`) live in `MarfaSDKTestSupport`.
- **`Auth/Flows/`** — three top-level types mirroring the TS SDK's `MarfaAuth` + `startDeviceFlow` split:
  - `MarfaAuth` (`@MainActor` class) — Authorization Code + PKCE via an ephemeral `ASWebAuthenticationSession`; `signIn(presentationContextProvider:)` returns a `TokenProvider`. The ephemeral session means each sign-in starts with a fresh cookie jar, so `signOut(_:)` actually ends the IdP session.
  - `DeviceFlow` — free-function `start(...)` returning a `DeviceFlowHandle` actor whose `awaitToken()` polls `/auth/device/token` per RFC 8628. No UI; suitable for headless / TV / watch.
  - `Passkey` (`@MainActor` enum) — exposes `enroll(issuer:presentationContextProvider:)` only, opening `/auth/passkey/enroll` in `ASWebAuthenticationSession` and letting the web flow run the WebAuthn ceremony. Native `ASAuthorizationController` against Better-Auth's `/auth/passkey/*` endpoints is intentionally not implemented: those are session-cookie-gated, not OAuth-bearer-gated, so a native client can't reach them. Passkey sign-in goes through `MarfaAuth.signIn(...)` — once enrolled, the web sign-in page surfaces a "Use a passkey" button.

**Internal auth contract is unified through `TokenProvider`.** The transport awaits `tokenProvider.currentToken()` for the `Authorization: Bearer …` header on every request. `ClientConfiguration.apiKey` is preserved for the static path (`MarfaClient(url:apiKey:)`, `fromKeychain(...)`, `saveToKeychain(...)`), which wrap the key in `StaticTokenProvider`. OAuth callers use `MarfaClient(url:tokenProvider:)` or `MarfaClient.synced(url:tokenProvider:storePath:)`. `URLSessionTransport` adds **refresh-on-401**: a 401 reports the refused credential via `tokenProvider.invalidate(_:)` and retries once with the replacement before surfacing as `UnauthorizedError`. Naming the token is what bounds recovery — `StoredTokenProvider` exchanges it only while it is still the credential in hand, so requests already in flight when a rotation lands don't each start their own refresh, and a rejected grant latches so later calls fail with no network at all.

### Multipart upload helper

`Transport.uploadMultipart(method:path:fieldName:filename:data:mimeType:query:)` — RFC 7578 envelope with one file part, routed through `rawRequest` so retry, auth-refresh, and rate-limit handling all apply. Used by `ProfileNamespace.uploadAvatar(...)`. Note: `BlobsNamespace.upload(...)` POSTs raw bytes with the MIME type as Content-Type and does not use this helper.

### System domain models (`DomainModels/System/`)

Hand-written because codegen-domain currently scans only `core.*` types: `Connection` (typed wrapper for `system.connection`, surfacing `kind: ConnectionKind`, `scopes`, `integrationRef`, `runtimeStatus`, etc.) and `Activity` (typed wrapper for `system.activity`, surfacing `severity: ActivitySeverity`, `summary`, `connectionId`). Both conform to `MarfaItem` so they slot into `client.items.list({type: ...})`, `typedQuery<T>()`, and the `queryConnections` / `queryActivity` factories. The closed enums `ConnectionKind` (`app | integration`) and `ActivitySeverity` (`info | warning | error | actionRequired`) are hand-written under `Types/Wire/Hand/` so apps pattern-match without comparing raw strings.

## Build

```bash
swift build
swift test
```

Real-Keychain tests tolerate `errSecMissingEntitlement` on unsigned SPM binaries; signed host apps exercise the real path. Integration tests point at staging via `MARFA_API_URL` and `MARFA_API_KEY`. Never run conformance or integration tests against production.

## CI — tiered validation

**CI is deliberately cheap on PR and thorough on main. Do not "strengthen" PR CI beyond compile + typecheck without a deliberate decision and an update to this note.**

- **PR pushes** run `swift build --build-tests` only — compile + typecheck, no test run. Catches roughly the same class of breakage as the full suite at about 30% the cost.
- **Runs on every PR, including docs-only ones.** The `pull_request` trigger carries no `paths-ignore`: the branch ruleset requires this check, and a required check that never reports (because a docs-only PR was path-filtered out) blocks the merge with no way for an agent to clear it. So a docs-only PR pays one compile + typecheck on the macOS runner — accepted as the cost of fully autonomous delivery (no human merge clicks). If those macOS minutes add up, the cost-free fix is a cheap Ubuntu gate job that greenlights docs-only PRs without compiling.
- **Merges to `main`** run the full suite: `swift build`, `swift test --parallel`, and both codegen freshness checks (wire types, domain models).
- **Both tiers** cache `.build/checkouts` and `.build` keyed on `Package.resolved` + source hashes, so source-only changes hit a warm cache.

**Why.** macOS runners bill at 10x Ubuntu, and running the full suite on every PR push was the largest CI cost driver across the org. The project is pre-release with no auto-deploy, so main breakages are a "fix before tagging" signal, not a user-facing incident. Full rationale lives in private design notes.

**When to revisit.** If this SDK ships to the App Store or picks up external consumers, re-evaluate the PR/main split. It's a shipping decision, not a calendar one.

**Local before pushing.** Run `swift test` locally before opening a PR or after a main-breaking change. CI on main catches it, but a broken main wastes minutes for everyone.

**Runner routing.** Both jobs read `runs-on` from the `CI_RUNNER` Actions variable, defaulting to `macos-latest`. `CI_RUNNER=self-hosted` routes them to a self-hosted Apple Silicon pool. Reverts to hardcoded `macos-latest` before this repo goes public.

## Conventions

- American English.
- Conventional Commits scoped by area: `feat(sse):`, `fix(transport):`, `refactor(client):`, etc. Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`.
- Explicit `CodingKeys` for snake_case ↔ camelCase mapping. Wire types expose camelCase externally.
- All public types are `Sendable`. Mutable shared state is actor-isolated or behind an `NSLock.withLock` critical section.
- No force unwraps. No `try!` outside test scaffolding where the invariant is unreachable.
- Swift Testing (`@Suite`, `@Test`, `#expect`), not XCTest.
- Comments are self-contained and make sense to anyone reading the repo cold. Explain *why* — the decision, constraint, or trade-off — not the *what* the code already states. Never reference internal trackers, ticket numbers, or project phases. If a comment doesn't earn its place, delete it; git carries the rest.

## Codegen

Three codegen tools, all SwiftPM-driven and committed to the repo. Shared rules across all three:

- **Generated files carry a `// Code generated by ...; DO NOT EDIT.` header.** Hand-edits are overwritten on the next regen — don't make them.
- **Freshness is gated in CI** by running the generator and `git diff --exit-code` against the output directory. A failure means the input moved or the generator emits differently than what's committed; resolution is always: regen locally, commit the delta.

### Wire types

Generated under `Sources/MarfaSDK/Types/Wire/Generated/` from the monorepo's OpenAPI spec. Stale files (types removed from the registry) are pruned on every run.

Inputs:
- **Spec snapshot** `scripts/openapi.json` — vendored copy of the monorepo's spec. Vendoring keeps CI self-contained (no cross-repo checkout, no shared secrets) and makes wire-type diffs readable alongside the regen. Don't edit it by hand; `sync-openapi.sh` refreshes it from `../marfa/openapi.json` and regenerates atomically.
- **Registry** `scripts/wire-types.json` — maps Swift type names to JSON-pointer paths into the snapshot.

Regenerate from the repo root:
```bash
./scripts/sync-openapi.sh   # monorepo's openapi.json changed (refreshes snapshot + regenerates)
swift run codegen-wire      # registry-only change (snapshot current)
```

Freshness check: `swift run codegen-wire && git diff --exit-code` against `Types/Wire/Generated/`.

Registry override mechanisms in `wire-types.json`:
- `numericIntFields` — global list of JSON fields spec'd as `number` but whole integers in the SDK (`version`, `schema_version`, `attempt`, `status_code`, …). Widen when a new such field lands or a field comes out `Double`.
- Per-type `fieldOverrides` — raw Swift type expressions substituted verbatim (e.g. `type_permissions: [String: TypePermission]`).
- Per-type `enumOverrides` — reuse existing hand-written enums (`KeyRole`, `ItemState`, `TypePermission`, `ExtensionPermission`, `EdgePermission`, `MetadataPermission`) instead of emitting fresh siblings.

Troubleshooting: confirm a pointer resolves with `jq -c 'getpath([...])' ../marfa/openapi.json`.

What stays hand-written (not generated):
- `Types/Wire/Hand/` — composite wrappers (`ItemWithMetadataWith`, `ItemEdgeGroup`), generic helpers (`PaginatedResult<T>`), envelopes (`ItemResponse`, `MetadataResponse`, `IntegrationsListResponse`, …), and closed enums the spec carries as plain strings (`ItemState`, `Tier`, `ConnectionKind`, `ActivitySeverity`, `FieldDefinition`, `SearchResult`).
- `Conflict/ConflictStrategy.swift` — `ConflictStrategy`, `ConflictData`, `ConflictResolver`, `ConflictResult`. The wire shapes (`ConflictResponse`, `ConflictSnapshot`, `MergePolicy`, `MergePolicyStrategy`) are generated from the 409 response schema.
- `Inputs/` — all SDK input shapes (`CreateItemInput`, `UpdateOptions`, `ListFilters`, `CreateKeyInput`, etc.).

### Domain models

Typed Swift structs per Marfa core type under `Sources/MarfaSDK/DomainModels/Generated/`. Each wraps a generic `Item`, exposing typed property accessors, a failable `init?(from:)` that validates the type string and required fields, and `toProperties()` for round-tripping into create/update calls. One struct per active core type — the active set is whatever the monorepo's `packages/types/core/` ships at codegen time.

Regenerate from the repo root:
```bash
./scripts/sync-types.sh     # monorepo's type schemas changed
swift run codegen-domain    # snapshot current
```
`sync-types.sh` copies `../marfa/packages/types/core/` into `scripts/MarfaCodegenCore/core-types/` then runs `codegen-domain`. The snapshot lives under `MarfaCodegenCore/` because that library bundles it as a resource for custom-type parent-chain resolution.

Freshness check: `swift run codegen-domain && git diff --exit-code` against `DomainModels/Generated/`.

`MarfaItem` protocol — hand-written at `DomainModels/MarfaItem.swift`. Provides `typeIdentifier: String`, `item: Item`, `init?(from:)`, `toProperties() -> [String: JSONValue]`, and default accessors for `id`, `type`, `state`, `createdAt`, `updatedAt`, `timestamp`, `version`, `source`, `sourceId`, `library`, `isActive`, `isTrashed`, `isArchived`.

Field conventions:
- Required fields are non-optional with `?? ""` / `?? 0` / `?? false` fallback (`init?` already guards presence).
- Optional fields are `T?`, returning `nil` when absent.
- Enum schema fields surface as `String?` (values in property doc comments).
- Child type fields shadow same-named parent fields for doc comments; the type mapping is identical either way.

### Custom types

Parallel tool for **consumer apps** with their own custom Marfa types. Generates the same-shaped `MarfaItem`-conforming struct as domain-model codegen, with inheritance flattened into one struct per type. Core schemas for parent-chain resolution (`parent: core.note`, etc.) ship bundled in the `MarfaCodegenCore` resource — consumers never vendor core types. Any `core.*` id in the source is rejected; that namespace is always out of scope regardless of include/exclude globs.

Ships as two executables plus one SwiftPM command plugin, all products of `MarfaSDK`, all consuming a single `marfa-codegen.json` at the consumer's repo root:
```bash
swift run codegen-custom-types                    # reads marfa-codegen.json, generates from local JSON schemas
swift run sync-custom-types                        # GET /types against a live instance, caches schemas, then generates
swift package generate-marfa-custom-types          # command-plugin wrapper; --sync invokes sync first
```

Input contract — `marfa-codegen.json`:
```json
{
  "schema": 1,
  "source": { "mode": "local", "directory": "MarfaTypes" },
  "output": { "directory": "Sources/MyApp/MarfaTypes/Generated", "accessLevel": "public" },
  "types": { "include": ["myapp.*"], "exclude": ["myapp.internal.**"] }
}
```
Mode `"live"` replaces `directory` with `cacheDirectory` and reads `MARFA_API_URL` / `MARFA_API_KEY` from env. Unknown `schema` versions fail fast.

Architecture:
- `MarfaCodegenCore` — internal library target, Foundation-only. Holds `ConfigLoader`, `SchemaLoader`, `SchemaResolver`, `NameMapper`, `CodeEmitter`, `FileWriter`, `Generator`, `SyncRunner`, plus the bundled `core-types/` JSON resource. Not a product.
- `codegen-custom-types` / `sync-custom-types` — executable targets at `scripts/`. Thin arg parsing over `Generator.run()` / `SyncRunner.run()`; sync uses URLSession directly, no `MarfaSDK` runtime dep.
- `GenerateMarfaCustomTypes` — command plugin at `Plugins/`. Declares `writeToPackageDirectory` and `allowNetworkConnections(.all)`.

Output shape mirrors domain-model codegen, with custom-type additions:
- `public static let typeSchemaVersion` — the schema version this struct was generated against; consumers compare with `MarfaItem.schemaVersion` at runtime for drift detection.
- Explicit `Sendable` conformance.
- Parent fields grouped under `// MARK: - Inherited from <parent.id>` sections.
- Swift-keyword field names emit with backtick escaping (`` `init` ``, `` `class` ``).
- Access level toggled by `output.accessLevel` — `public` (default) or `internal`.

Consumer freshness check — add to their own CI:
```yaml
- run: |
    swift run codegen-custom-types
    git diff --exit-code -- Sources/MyApp/MarfaTypes/Generated
```

Testing model (`CodegenCustomTypesTests`):
- Unit tests cover `NameMapper`, `ConfigLoader`, `SchemaResolver`, filters, and the `Generator` flow.
- `GoldenTests` runs the full generator against `Fixtures/schemas/*.json` and byte-compares to `Fixtures/expected/*.swift`.
- `CodegenCompileCheckTests` — a second target whose sources are the pre-generated Swift files in `CompileCheck/`; it fails to build if output shape regresses.
- `SyncTests` uses an in-memory `HTTPFetcher` mock. No live-server integration test — the mock covers the contract and keeps CI hermetic.

Refreshing golden files after an intentional emitter change:
1. Update `scripts/MarfaCodegenCore/CodeEmitter.swift`.
2. Run the generator against `Tests/CodegenCustomTypesTests/Fixtures/schemas/` into a scratch dir.
3. Copy the outputs over both `Fixtures/expected/*.swift` and `CompileCheck/*.swift`.
4. `swift test --filter CodegenCustomTypesTests` to verify.
