# MarfaSDK

Swift SDK for the Marfa API. Equivalent to the TypeScript `@withmarfa/sdk`.

Before re-deriving documented surfaces (types, edges, runtime substrates, connections, auth flows) from source, query the docs MCP at `https://docs.marfa.so/mcp` (or `marfa docs search "<query>"` from CLI). Docs live **only** in `withmarfa/docs` — never author docs pages here; when a change touches a public surface, open a companion `withmarfa/docs` PR and link it.

## Architecture

- **SPM package**, zero external dependencies. Built from Foundation, Security, SwiftData, and `os`.
- **Apple platforms only:** iOS, macOS, visionOS, watchOS, tvOS. `Package.swift` is the source of truth for minimum-deployment versions.
- **Swift 6** language mode, complete strict concurrency.
- **Two products:** `MarfaSDK` (client library) and `MarfaSDKTestSupport` (public test scaffolding: MockTransport, InMemoryKeychain, SwiftDataHelpers). Test support has no semver stability across SDK minor versions.
- **`Transport` protocol** abstracts HTTP. `URLSessionTransport` is the production impl; `MockTransport` is in test-support.
- **Namespaced API:** `client.items.create()`, `client.metadata.get()`, etc. Full set: `items`, `metadata`, `extensions`, `edges`, `blobs`, `types`, `keys`, `credentials`, `webhooks`, `profile`, `connections` (with nested `leaseTokens` and `inboundWebhooks`), `integrations`, `spaces`, `admin`, `auth`.
- **`JSONValue`** enum for arbitrary JSON (Codable, Sendable, Hashable).
- **Dates as ISO 8601 strings**, not `Date` — apps parse as needed.
- **Error hierarchy:** `open class MarfaError` base with `final class` subclasses (`NotFoundError`, `UnauthorizedError`, `ForbiddenError`, `ValidationError`, `ConflictError`, `NetworkError`, `ResponseDecodingError`). Pattern-match on subclasses: `catch let error as NotFoundError`.

### Local store & sync

Four actors wire together for synced mode; `MarfaClient.local(path:)` runs pure-local (no mutations enqueued).

- **LocalStore** (`@ModelActor`) — SwiftData `ModelContainer` from `MarfaModelContainer.make(path:)`. `@Model` classes under `LocalStore/Schema/`, versioned via `MarfaMigrationPlan`. CloudKit-compatible from day one: no `#Unique`, all properties defaulted, all relationships optional with explicit inverse, no `.deny` rules, Codable enums via rawValue.
- **MutationQueue** (`@ModelActor`) — shares LocalStore's `ModelContainer`; cross-actor saves serialize at the SQLite layer. One record per SDK mutation verb (`MutationKind`); `fetchAll()`/`remove(id:)`/`recordFailure(id:error:)` drain API returning Sendable `PendingMutationRecord` DTOs. Persists `last_event_id` cursor for SSE reconnection. `enqueueBlobUpload`/`purgeItem`/`dropMutationsReferencingLocalId` each commit as one `modelContext.save()`.
- **ConnectionState** — `.offline`, `.connecting`, `.online`, `.syncing`, plus `isReachable`.
- **ConnectionStateManager** (`actor`) — wraps `NWPathMonitor`; bridges `DispatchQueue` to actor via `Task { await self?.handlePath(_:) }`. Multicasts to `AsyncStream<ConnectionState>` subscribers via UUID-keyed `continuations`. `markSyncing()`/`markOnline()` for engine transitions.
- **SyncEngine** (`actor`) — observes `ConnectionStateManager.stateUpdates`; on `.connecting` opens `GET /events` SSE with `Last-Event-ID` cursor; applies `item.*`, `edge.*`, `metadata.changed` to LocalStore via upsert; after stream closes, drains MutationQueue (markSyncing while replaying, markOnline when done); reconciles local-id → server-id for `createItem` replays. Writes go through the **`LocalStoreWriting`** protocol rather than the concrete actor — the store-side counterpart to `Transport`, so a test can substitute a store whose writes fail. SwiftData accepts everything the engine can construct, which otherwise leaves that whole half of a sync cycle untestable.

Both factories (`MarfaClient.local(path:)`, `MarfaClient.synced(url:apiKey:storePath:connectionManager:)`) are **`async throws`** — `@ModelActor` construction must run off the main actor, so every call site is `try await`. For synced clients the caller invokes `client.syncEngine?.start()`.

- **Local-first reads** — `metadata.listTags()` aggregates tags by fetching metadata rows where the parent item's `stateRaw != "trashed"` and bucketing in Swift (SwiftData predicates can't reach inside the JSON `tagsData` blob). `edges.listToTargets(targetIds:edgeType:limit:)` batches inbound-edge lookup: one local fetch with `Set.contains(targetId)`, bounded `TaskGroup` fan-out remotely (cap via `ClientConfiguration.maxBackrefBatchConcurrency`, default 8).
- **Local search** — `LocalStore.searchItems(text:filters:)` (`LocalStore/LocalStoreSearch.swift`) narrows on `type` / `stateRaw` / `tierRaw` in a predicate, then scans the survivors in Swift over `title` and `body`; `properties` is a JSON blob the predicate engine can't see, and SwiftData has no FTS index. Takes the same `SearchFilters` as the remote call and mirrors the server's `system.*` and trashed exclusions plus its default limit of 20. It diverges on matched fields (only `title` and `body`, so types keying their text elsewhere — `core.entity*`, `core.highlight` — never match), tags (indexed as text server-side, not matched locally), `type` (literal, no subtype inheritance), `limit` range (server `1...100`; locally non-positive returns empty and larger values are honored), ranking (ordinal, not BM25) and snippets (none). All are listed in the method's doc comment alongside its measured cost, which is tens of milliseconds per thousand rows — `limit` caps the answer, not the work. `client.search(query:)` resolves through it whenever the client has a store, synced or not — one interface, local baseline. Sync used to switch it off, so the same call meant a local scan or a network round trip depending on a setting made once and forgotten. `client.searchRemote(query:)` is the explicit way to ask the index instead, for the cases the divergences above rule out: BM25 ranking, snippets, or a corpus wider than what has synced to the device.
- **Predicate safety** — `LocalStore/Schema/PredicateConventions.swift` documents the predicate-safe subset every fetch must use; `Tests/MarfaSDKTests/PredicateSafetyTests.swift` regresses every supported shape so a predicate that compiles but crashes at runtime fails CI. Key rules: predicate against `*Raw` columns not Codable enum cases; use captured-value `&&` short-circuits not runtime `Predicate<T>` composition; use `prop != ""` for empty-string filtering (`isEmpty`/`!isEmpty` both misbehave in current SwiftData).
- **CloudKit readiness** — `cloudKitDatabase` is consumer-set on `MarfaModelContainer.make(...)`; the schema is CloudKit-mirrored regardless. `swift run cloudkit-smoke` validates the schema against a developer's CloudKit container (see `Sources/MarfaSDK/LocalStore/README.md`). Manual run only — no CloudKit entitlements on CI runners.

### Reactive layer (@Observable, SwiftUI)

All query objects are `@Observable @MainActor` — pass directly to SwiftUI views; changes propagate without `ObservableObject`. Shared listener machinery lives in `RefetchObserver` (`Reactive/MarfaStore.swift`).

- **MarfaStore** (`@Observable @MainActor`) — vended via `client.makeStore()` (`nil` for network-only clients). Factory for live query objects; holds the shared `ModelContainer`, the `LocalStore` actor, and the `ProfileNamespace` reference.
- **ItemQuery** — tracks `[Item]` for a `ListFilters`; subscribes to `ModelContext.didSave`, debounces 50 ms (`Reactive/RefreshDebounce.swift`), refetches on the `@MainActor`. Fields: `items`, `isLoading`, `error`; `stop()` cancels.
- **TypedItemQuery<T: MarfaItem>** — like `ItemQuery` but maps records through `T.init?(from:)`. Backs `store.queryConnections(kind:state:)` (`TypedItemQuery<Connection>`) and `store.queryActivity(severity:limit:)` (`TypedItemQuery<Activity>`).
- **SingleItemQuery** — one item by id; `item` is `nil` when purged.
- **EdgesQuery** — outbound edges for a `sourceId`; optional `edgeType` and `limit`. Second initializer tracks every edge of a type space-wide.
- **BackrefsQuery** — inbound edges for a batch of `targetIds`; `edgesByTarget: [String: [Edge]]` keyed by every requested id (unknown ids stay present with `[]`). Factory: `store.queryBackrefs(to:edgeType:limit:)`.
- **TagsQuery** — `[TagWithCount]` sorted count desc, tag asc (same ordering as `metadata.listTags()` and the server). Factory: `store.queryTags()`. Aggregates in Swift over a relationship-prefetched fetch.
- **ItemsWithMetadataQuery** — items + metadata composite. Two fetches per refresh, 1:1 join in Swift.
- **SearchQuery** — `[SearchResult]` for a fixed search term. Factory: `store.querySearch(text:filters:)`. The one query that does **not** work on the main actor: it delegates the whole scan to the `LocalStore` actor and only publishes results back, because search decodes each candidate's `properties` JSON. The term is fixed per query — for search-as-you-type, build a new query per term and `stop()` the old one.
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

### Route coverage (`Tests/MarfaSDKTests/RouteCoverageTests.swift`)

Compares the routes the SDK calls against the operations `scripts/openapi.json` declares, **in both directions**. Nothing else does: no generator reads the spec's `paths`, so before this the two surfaces drifted apart silently. It runs under `validate` with the rest of the suite and needs no separate wiring.

Call sites are recovered by finding every `transport.<callee>(` in `Sources/MarfaSDK` and reading its argument list — parenthesis, string and interpolation aware, over a comment-stripped copy of the source — for a literal `method:` and a `path:` that is one whole string literal beginning with a slash. `eventStream` is the one shape with no `method:`; it is a GET by construction.

**What that guarantees, exactly:** every call written as `transport.<callee>(…)` in those sources is either read into a `METHOD /path` or reported by file and line with the reason it could not be. Four shapes are named rather than dropped: a defaulted verb, a verb held in a variable, a path composed from more than one literal, and a path composed inside one literal by leading with an interpolation. The two composed shapes matter most — `"/items" + suffix` would otherwise read as `GET /items`, a route the spec declares, so neither direction of the check would fire — and they are refused alike.

**Prose never counts as a call, in either direction.** This is the part that was wrong three times, so it is stated as the property rather than as the mechanism. *Prose* means anything the source contains that is not code the compiler runs. Two members are modeled — comments and string literals — and **the definition is deliberately larger than that list**, because narrowing it to what has been implemented is the exact move that produced the last three defects here. A regex literal is prose by this definition and is not modeled; it is refused instead, by a test that fails if one appears under `Sources/`. When you meet a construct that is prose and is not in the list, that is a gap in the implementation rather than a case outside the rule. Over-blanking, where code is taken for prose, hides call sites; the raw file is scanned for `transport.<callee>(` and every match must be accounted for. Under-blanking, where prose is taken for code, *invents* call sites, and that is the silent direction — an invented route subtracts a genuine declared-but-unwrapped operation from the report and takes the suite green over a real gap. Two things answer it: call recovery refuses a receiver sitting inside a string literal, and a separate comment scan — one that ignores literals, measures every `//` and `/*` occurrence independently, and so can only over-report — must find no unblanked comment text across a recovered call. Neither trusts the stripper.

**The scanner models raw string literals**, which is load-bearing rather than fastidious: `#"say "hi"#` holds an odd number of quotes, and naive pairing then reads the rest of that line as literal text and silences both scope guards on a real call. `Inputs/BulkInputs.swift` carries a raw literal today. CRLF line endings are handled for the same reason — `Array(String)` yields `\r\n` as one grapheme, so comparing against `"\n"` silently mis-lexed a whole file and reported every finding at line 1.

**`ScannerBehavior` drives the scan with constructed sources**, named for what each witnesses. **Not one per admitted limitation** — that was claimed and was not true, and an uncounted claim is the thing this file keeps getting caught by. Conditional compilation is admitted in the scanner's own docblock and nothing pins it; the regex-literal limitation is pinned by a refusal rather than by a witness, because the silent direction is not one a constructed input can be left sitting in. Sources that must never exist under `Sources/` live there: a raw literal that desynchronizes quote pairing, a route spelled inside a multiline literal, a file with CRLF endings. The tests that pin *limitations* assert a shape goes unreported, so closing one fails a test and forces the prose here to be corrected with it.

Two further tests check the scan's *scope*: no `method:` or route-shaped `path:` argument may sit outside a recovered call (both read code positions only, so a `method:` inside a log line is not mistaken for an escaped HTTP call), and the excluded `Transport/` directory must hold no route literals. That last one is narrow on purpose and is worth knowing before trusting it: it finds a string literal beginning `"/` followed by a letter, and nothing else. A composed path (`"\(base)/items"`, `"/" + segment`, a multiline literal), a path with no leading slash, and one whose first segment is a parameter (`"/{id}/x"`) are all invisible to it — and it checks *literals*, not calls, so a helper in `Transport/` forwarding a caller's path passes because there is no literal to find. It narrows the excluded directory; it does not close it.

**The shapes found to escape** — which is not the same as the shapes that escape, and the difference is the whole lesson below. A call on a receiver rebound away from the name `transport`, whose callee takes no `method:` and whose `path:` is neither slash-leading nor interpolation-leading, escapes every guard; guarding the rebinding is not cheap, since every namespace writes `self.transport = transport`. A string literal nested inside an interpolation ends the outer literal early, which costs a false report rather than a miss. Both are pinned in `ScannerBehavior`.

**Attack the boundary, not only the internals.** Every defect found in this check across three rounds was reached the same way: not by finding a bug in the code, but by testing whether the *stated scope* of its guarantee was true. "Unreachable" had never had the input constructed. "Comments" was the wrong word for "prose", and a route written in a string literal walked through every guard because literals sat outside a boundary nobody had questioned. **A guarantee's stated scope is a claim like any other, and a claim that is only written down is a claim nothing checks.** When you state what a check delivers here, state what it cannot see in the same breath, say which of those you constructed an input for, and pin the ones you are leaving open with a test named for the limitation.

**What it does not guarantee:** HTTP that never goes through `Transport` is outside the check entirely. The OAuth code (`OAuthDiscovery`, `TokenProvider`, `DeviceFlow`, `MarfaAuth`, `MarfaSession`) builds `URLRequest`s directly, and `Passkey` hands a URL to a system browser. Most of those endpoints are read out of the discovery document at runtime, so there is no path literal to compare and no spec operation to compare it to — but "every route the SDK calls" would be the wrong way to describe what is counted.

Two maps, and the distinction between them is the point:

- **`deliberatelyUnwrapped`** — the spec declares it, the SDK does not call it, and that is a decision. Each entry carries its reason. Several read "no decision on record", which is honest rather than a placeholder: the operation is unwrapped and nothing explains why. Those are the entries worth revisiting; the rest are settled.
- **`undeclaredUpstream`** — the SDK calls it and the spec does not declare it. Not a missing wrapper: the wrapper works, and the route is live. Two causes, needing opposite responses. Nine of the fourteen are on the server's `INTERNAL_OPERATION_IDS` list and are dropped from the public reference on purpose — nothing to fix, and a PR to document them would reverse a stated policy. The other five are plain Hono handlers the `createRoute` reflection cannot see, which the server's `EXTRA_PATHS` hatch could document and does not; nothing says whether that was decided, so they read "no decision on record" too.

**Against a snapshot that trails.** `scripts/openapi.json` is 4 operations behind the monorepo's committed `openapi.json`, all unwrapped, so the count of unwrapped operations is 28 rather than the 24 the test can see — a floor, since neither document was compared against a running server. `sync-openapi.sh` is run by hand and the `freshness` job re-runs codegen against the committed snapshot rather than re-syncing it, so nothing closes that on its own.

**When it fires**, read which direction. A new entry in the first means an operation appeared in the snapshot and nothing wraps it — write the wrapper, or add it to the map with the reason you chose not to. A new entry in the second means the SDK calls something the document does not describe: establish which cause before recording it, because the remedy differs and for the internal ones the remedy is nothing. The suite also fails on entries that have gone stale in either map, so a map cannot outlive what it describes.

## Build

```bash
swift build
swift test
```

Real-Keychain tests tolerate `errSecMissingEntitlement` on unsigned SPM binaries; signed host apps exercise the real path. Integration tests point at staging via `MARFA_API_URL` and `MARFA_API_KEY`. Never run conformance or integration tests against production.

## CI

Two jobs in `.github/workflows/ci.yml`.

- **`validate` — build + full test suite. Runs on every PR and every merge to `main`.** `swift build` then `swift test --parallel`. This is the gate: a change is not validated until its tests have run, and a pull request is the only place that check can still stop something.
- **`freshness` — the three codegen regens plus their diffs. Main and `workflow_dispatch` only.** It guards against drift in the vendored OpenAPI and core-type snapshots, which a source-only PR cannot introduce, and it costs three generator runs to say so. Running it per push would spend a lot to catch a class of change that arrives through a snapshot refresh, where the regen is part of the commit anyway.
- **`validate` runs on every PR, including docs-only ones.** The `pull_request` trigger carries no `paths-ignore`: the branch ruleset requires this check, and a required check that never reports (because a docs-only PR was path-filtered out) blocks the merge with no way for an agent to clear it. So a docs-only PR pays one build + test on the macOS runner — accepted as the cost of fully autonomous delivery (no human merge clicks). If those macOS minutes add up, the cost-free fix is a cheap Ubuntu gate job that greenlights docs-only PRs without compiling.
- **Both jobs build from their runner workspace without a remote `.build` cache.** Swift precompiled modules embed absolute module-cache paths, so restoring build artifacts after a workspace moves produces an immediate `SwiftShims` path mismatch. The package has no external dependencies and a cold build is short enough that the remote cache adds failure state without earning its place.

**Why tests moved onto PRs.** They were main-only, on the reasoning that macOS runners bill at 10x Ubuntu and the project is pre-release, so a broken `main` is a "fix before tagging" signal rather than an incident. That held until a release tag was cut from a commit whose tests had never run: nothing between "compiles" and "tagged" ever executed the suite, and the missing fix shipped in a version number. Test cost on a PR is small and predictable; the alternative is discovering the same thing from a release artifact.

**Local before pushing.** Run `swift test` locally anyway. CI catching it is a slower loop than catching it yourself.

**Runner routing.** Both jobs read `runs-on` from the `CI_RUNNER` Actions variable, defaulting to `macos-latest`. `CI_RUNNER=self-hosted` routes them to a self-hosted Apple Silicon pool. Reverts to hardcoded `macos-latest` before this repo goes public.

## Public surface

`scripts/public-surface.txt` records every public and open declaration in `MarfaSDK` — path, kind, declaration — **as of the last release**. `validate` regenerates the surface at HEAD, compares the two, and fails when the `## [Unreleased]` section of `CHANGELOG.md` does not name a declaration that was added, removed or retyped.

```bash
./scripts/public-surface.sh                 # rewrite the baseline (release cuts only)
./scripts/public-surface.sh /tmp/head.txt   # write the current surface somewhere else
swift run public-surface check scripts/public-surface.txt /tmp/head.txt CHANGELOG.md
```

- **Regenerate the baseline at a release cut and never in between** — after the Unreleased section has been renamed to the version being cut, so the two moves land in one commit. Forgetting is loud rather than silent: the next change's check reports the last release's entries as unaccounted for, because they are no longer in Unreleased.
- **Additions are held to the same standard as removals**, which is the part that reads as excessive and is not. A release analysed as purely additive broke a consumer on the first compile, because the SDK added a public name the consumer had already invented for the same concept. That is the predictable consequence of closing a gap a consumer worked around, so a changelog that lists the names a version adds lets them see it before they bump.
- **Members roll up.** A type that arrives or leaves is reported once rather than once per member, and an enum's cases are reported as the enum, because a closed enum gaining a case breaks an exhaustive switch and that is a fact about the enum.
- **The mention test is literal**, matching whole names: `Foo`, `Foo.bar`, or the call spelling for a namespace method (`auth.me`). It asks whether the name a consumer would search for is on the page, not whether the prose is good.
- **What it cannot see: protocol conformances.** Dropping a public conformance is source-breaking and lives in the symbol graph's relationships, under a pile of synthesised `Sendable` and `Copyable` entries. Separating declared conformances from synthesised ones is its own piece of work, and this check is silent on that class.
- **`MarfaSDKTestSupport` is deliberately outside the snapshot**, because it carries no semver stability across SDK minor versions and holding a changelog entry against every change to it would demand records this project does not promise.

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
