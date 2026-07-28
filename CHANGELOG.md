# Changelog

All notable changes to the Swift SDK are documented here.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Local search.** `MarfaStore.querySearch(text:filters:)` returns a live
  `SearchQuery` over `title` and `body` in the local store, so search works
  offline and without a round trip. It takes the same `SearchFilters` as
  `MarfaClient.search(query:filters:)` — `type`, `state`, `tier`, `tags`,
  `limit` — and mirrors the server's exclusion of `system.*` and trashed
  records plus its default limit of 20, so a screen can move between the two.
  Where they differ: only `title` and `body` are matched — so types keying
  their text elsewhere (`core.entity` and its subtypes, `core.highlight`, and
  a captured email's `subject`) never match at all — tags are filterable but
  not searchable, `type` is compared literally rather than resolving
  subtypes, `limit` accepts values the server's `1...100` would reject,
  ranking is ordinal rather than BM25, and there are no snippets. All are
  documented on the method, alongside its cost: tens of milliseconds per
  thousand rows scanned, with `limit` capping the answer rather than the
  work. An abandoned search is cancelled at the scan rather than run to
  completion.
- **`MarfaClient.search(query:filters:)` resolves locally on a pure-local
  client** instead of failing against the placeholder URL, matching how every
  namespace already behaves. Synced clients still query the server, whose
  index beats a local scan.

### Changed

- **CI runs the full test suite on pull requests.** Tests were main-only, so
  nothing between "it compiles" and "it's tagged" ever ran them. The codegen
  freshness checks stay main-only — a source-only PR can't make a vendored
  snapshot stale.

### Fixed

- **The test suite is deterministic under `swift test --parallel`.** Four
  auth suites shared `OAuthDiscovery.shared`, a process-wide cache keyed by
  issuer origin, and cleared it with a `reset()` that evicts every origin
  rather than the caller's own. Running concurrently, they destroyed each
  other's cached endpoints mid-test and left scripted HTTP responses
  unconsumed, failing roughly a quarter of full runs. Each test now takes an
  issuer origin of its own, so it starts cold without touching state another
  test owns, and no test calls the process-wide reset.

- **OAuth discovery accepts the issuer identifier as the caller wrote it.**
  The published issuer was compared against a canonicalized form of the
  request, so a server whose issuer identifier legitimately ends in a slash,
  or a consumer who writes an explicit default port, could never match and
  was rejected outright. RFC 8414 §3.3 requires the comparison to be verbatim;
  the canonical form still keys the cache and builds the well-known URL, so
  two spellings of one server share a fetch and are each checked on their own
  terms.

- **`SyncEngine.stop()` is a quiescence boundary, not a cancellation
  request.** It now awaits work installed into a lifecycle slot after it took
  its snapshot, so it can no longer return while an engine-owned task is
  still running. It also finishes every open `events` stream, and `events`
  registers its continuation before the property returns, so subscribing and
  immediately stopping no longer strands a consumer on a stream that never
  yields and never ends.

- **A stream closing inside a teardown no longer touches the connection
  manager** or schedules a reconnect nudge that would outlive the stop.
  Network monitoring is rebuilt per lifecycle, so a restarted engine observes
  path changes again instead of staying inert.

- **A clean drain is only stamped after a fresh, successful empty-queue
  read.** A mutation enqueued while a replay cycle was in flight left the
  queue non-empty but still recorded the cycle as clean, so `fullSyncState`
  reported `.synced` with work outstanding.

- **SDK `ModelContainer` construction is serialized.** Overlapping
  `MarfaModelContainer.make(path:)` calls raced inside SwiftData.

### Security

- **A crafted issuer and client id could read and destroy another account's
  stored token.** Credential accounts are namespaced by version, and the
  version was separated with a colon — the same delimiter a legacy
  host-keyed account uses. Both the host and the client id come from the
  caller, so an issuer whose host is literally `v2`, plus a client id
  spelling out another account's field encoding, reconstructed that
  account's Keychain key byte for byte. The legacy-token migration then read
  the victim's slot as its own legacy value, copied it into the attacker's
  account and deleted the original. The version is now separated with `.`,
  which a legacy key can never carry in that position, making the two
  namespaces disjoint by construction. Account fields are also
  length-prefixed, so a delimiter inside an issuer or client id cannot shift
  the boundary between them.

- **Discovery documents must name the issuer they were fetched for.** The
  SDK did not check the `issuer` an authorization server published, so a
  server reachable at one issuer could hand back endpoints belonging to
  another. The check is applied per caller rather than once per cached
  document.

## [11.3.0] — 2026-07-25

Ship the 11.2.0 fix. The `v11.2.0` tag was cut one commit early, so it points
at the single-flight refresh work and does not contain the 401 handling its
notes describe. Anything pinned to 11.2.0 therefore still signs the user out
on a 401 for a clock-valid token. Pin 11.3.0 to get the behavior documented
below; the release notes for 11.2.0 are left as written so the record of what
was intended stays intact.

No source changes over 11.2.0 beyond the commit that tag missed.

### Fixed

- **A 401 on a clock-valid token now forces one refresh and one retry** — see
  the 11.2.0 notes below for the full description. This release is the first
  tag that actually contains it.

## [11.2.0] — 2026-07-24

Note: this tag does not contain the change described here. See 11.3.0.

Recover a session when the server rejects an access token that has not yet
expired. Refresh was proactive only — it renewed inside a window before
clock expiry — so a token revoked, rotated out, or outlived by a queued
request came back 401 with nothing able to renew it. The transport retried,
the provider handed back the same token from storage, and a session a live
refresh token could have saved ended in a sign-in prompt.

### Fixed

- **A 401 on a clock-valid token now forces one refresh and one retry.**
  The transport reports the refused credential to the provider, which
  exchanges it and lets the retry go out with the replacement.
- **Auth failures raised while re-minting a header keep their type.** An
  `OAuthError` surfacing from the token provider mid-request was wrapped in
  `NetworkError`, hiding the OAuth code callers branch on and presenting a
  dead session as a connectivity problem.

### Added

- **`TokenProvider.invalidate(_ rejected: Token)`** — the token-scoped
  form of `invalidate()`, called by the transport on a 401 with the exact
  credential the server refused. Additive: the protocol supplies a default
  that forwards to `invalidate()`, so an existing custom provider keeps
  working unchanged. `StoredTokenProvider` implements it and exchanges the
  token only when it is still the one it hands out, so requests already in
  flight when a rotation lands do not each trigger their own refresh.

## [11.1.0] — 2026-06-16

Normalize all prose to American English across source, doc comments, string
literals, and markdown — matching the spelling convention already applied to
the server and docs repos. Contract and enum literals (e.g. `cancelled`,
`completed`, `failed`) are unchanged.

### Changed (breaking, shipped as a minor)

- **`RetryPolicy.honoursRetryAfter` renamed to `honorsRetryAfter`** — the
  public property and its initializer parameter both change spelling.
  Source-breaking for any caller that set the parameter or read the property by
  name; the type, default, and behavior are identical. Shipped as a minor
  release at the maintainer's discretion.

## [11.0.0] — 2026-06-05

Correctness fix: align `ConnectionKind` with the server. The server reduced
`system.connection.kind` to `app | integration` — the `tenant` kind was
removed and the server now returns 400 for `kind=tenant`. The SDK still
shipped a `.tenant` enum case the server rejects.

### Removed

- **`ConnectionKind.tenant`** — the reserved cross-tenant case is gone. The
  enum is now exactly `app | integration`, matching the server's
  `system.connection.kind` enum. Source-breaking for any caller that
  referenced `.tenant`; there was no live server path for it.

### Changed

- **`ConnectionKind` now decodes only `app | integration`** — decoding a
  `"tenant"` wire value fails loudly (as it does for any unknown value),
  rather than producing a kind the server will reject on write.

## [10.0.0] — 2026-05-24

Parity with the server's v7.0.0 release (`@withmarfa/sdk@7.0.0`,
`@withmarfa/shared@7.0.0`). New credential surface, an extended install
input, and a stack of new typed domain models pulled in from the
monorepo.

### Added

- **`client.credentials` namespace** — `CredentialsNamespace` with two
  factory methods. `createOAuthProvider(_:)` creates a
  `system.credential` of kind `oauth_token` for OAuth-based integrations,
  used to share one Google OAuth provider row across every
  `google.*` integration. `createApiToken(_:)` creates a credential of
  kind `api_token` for token-based integrations, used by Todoist, Readwise,
  and Raindrop. Both routes are tenant-admin
  gated server-side.
- **`CredentialKind` enum** (`apiKey | oauthToken | apiToken`) under
  `Sources/MarfaSDK/Types/Wire/Hand/`. Hand-written closed enum so apps
  can pattern-match without comparing raw strings.
- **`AuthScheme` enum** (`bearer | token | basic`) — controls which
  `Authorization` header the Marfa proxy stamps on outbound calls when
  the connection's credential is of kind `api_token`. Mirrors the
  server's `auth_scheme` field — Readwise, GitHub PATs, and a
  few other upstreams need `Token` instead of `Bearer`.
- **`CreateOAuthProviderCredentialInput`**, **`CreateApiTokenCredentialInput`**,
  **`CreatedCredential`** input/response types under
  `Sources/MarfaSDK/Inputs/CredentialInputs.swift`. Mirror the server's
  `POST /credentials/oauth-provider` and `POST /credentials/api-token`
  shapes.
- **`ConnectionInstallInput` gains `credentialRef: String?` and
  `configuration: [String: JSONValue]?`** (regenerated wire type). Pass
  the credential id returned by ``CredentialsNamespace`` so the new
  connection inherits the shared upstream credential; pass
  `configuration` for per-connection overrides, including
  `upstream_base_url`.
- **New typed domain models** auto-pulled from the monorepo's core type
  set: `todoist.task` (TodoistTask), `readwise.book` / `readwise.highlight`
  (ReadwiseBook / ReadwiseHighlight), `raindrop.raindrop` / `raindrop.collection`
  (RaindropRaindrop / RaindropCollection), `withmarfa.captured_email`
  (MarfahqCapturedEmail), `google.tasks.task` / `google.contacts.contact` /
  `google.drive.file` (GoogleTasksTask / GoogleContactsContact /
  GoogleDriveFile). 32 core types total — every type the monorepo's
  `packages/types/core/` ships.

### Fixed

- **`codegen-domain` now backtick-escapes Swift reserved keywords**
  (`public`, `private`, `default`, etc.) when they appear as JSON field
  names. Surfaced by `raindrop.collection.public: Bool` — the previous
  generator emitted `var public: Bool?` which failed to compile. The
  fix mirrors what the custom-type codegen has had since day one.

### Changed

- **`MarfaClient` constructor now wires `credentials`** alongside
  `connections`, `integrations`, etc. No source-breaking impact on
  existing call sites — the new namespace is additive.

### Internal

- `scripts/openapi.json` re-synced from monorepo `main` at `32906a1`.
- `scripts/MarfaCodegenCore/core-types/` re-synced from monorepo
  `packages/types/core/` at `32906a1`.
- All 619 SDK tests pass.

## [9.0.0] — 2026-05-22

OpenAPI re-sync for the server's `workspace_admin` → `tenant_admin` role rename.

### Changed

- **`KeyRole` gains a `tenantAdmin` case.** The server renamed the `workspace_admin` role to `tenant_admin`; the SDK's `KeyRole` enum was missing the mid-tier role entirely — it carried only `admin` and `member`, so decoding an `ApiKey` or `CreatedKey` whose role is the mid-tier value threw a decoding error. `KeyRole` is now `admin | tenantAdmin | member`, with `tenantAdmin` carrying the raw value `tenant_admin`. Adding a public enum case is source-breaking for exhaustive `switch` statements over `KeyRole`, hence the major bump.
- **`WebhookDelivery.success` renamed to `succeeded`.** The server renamed the `outbound_webhook_deliveries.success` column to `succeeded`; the regenerated wire type follows. Consumers reading `delivery.success` update to `delivery.succeeded`.

### Internal

- `scripts/openapi.json` re-synced from the monorepo. Doc comments across `MarfaClient`, `AuthNamespace`, `TenantsNamespace`, `ConnectionsNamespace`, and `TenantQuota` updated from `workspace-admin` to `tenant-admin`.

## [8.2.0] — 2026-05-22

OAuth endpoint discovery, plus the async bulk-action surface.

### Changed

- **OAuth endpoints are discovered, not hardcoded.** `MarfaAuth` and `DeviceFlow` now fetch `${issuer}/.well-known/oauth-authorization-server` and resolve the token / authorize / revoke / device endpoints from it. The server's OAuth surface moved to `/auth/oauth2/*`, while the SDK still constructed the old paths, so refresh, code-flow exchange, and revoke 404'd against an updated server. The discovery doc is fetched once and cached for the process; a discovery failure raises a clear error rather than falling back to dead paths. Public `MarfaAuth` / `DeviceFlow` call sites are unchanged — discovery happens internally.

### Added

- **Async `bulk_action` jobs.** The remote-mode `bulkAction(_:options:)` signature is unchanged for callers — internally it now distinguishes the `200` (dry-run) and `202` (queued) responses and polls `GET /items/bulk_action/jobs/:id` to a terminal status, resolving with the embedded `BulkActionResult` exactly as the synchronous endpoint did. New surface: `BulkActionJob` / `BulkActionJobStatus`, `BulkActionPollOptions`, `bulkActionAsync(_:)`, `bulkActionStatus(jobId:)`, `bulkActionCancel(jobId:)`, and `BulkJobCancelledError` / `BulkJobFailedError`. Synced mode waits for the server-side job to terminate before settling the mutation; pure-local mode is untouched.

### Internal

- Content-correctness sweep across doc comments and strings.

## [8.1.0] — 2026-05-17

Released to consumers but not recorded here at the time — backfilled.

### Added

- **`client.tenants` namespace** and **`client.connections.previewEvent`**.

### Internal

- Test-coverage hardening for auth, transport, and namespaces.

## [8.0.0] — 2026-05-17

Combined major bump. Includes `waitForCondition` promotion, a SyncEngineTests split, and DeviceFlow testability seams that shipped to `main` after `v7.0.0` but were never released to consumers. The DeviceFlow parameter rename drives the major. Also lands the OAuth-surface carry-across: refreshed OpenAPI snapshot (61 → 68 paths), two new top-level namespaces (`client.admin`, `client.auth`), `source_id` on item updates, and the `createWithAttachments` helper.

### Added

- **`client.admin`** — platform-admin-only operator surface backing the `my admin` CLI command tree. Throws `LocalModeUnsupportedError` in pure-local mode; non-platform credentials get a `403 forbidden`.
  - `client.admin.tenants.list()` — every tenant + status.
  - `client.admin.tenants.get(id:)` — single tenant + per-tenant quota overrides + recent activity.
  - `client.admin.tenants.suspend(id:)` / `unsuspend(id:)` — flip tenant `status`. Idempotent.
  - `client.admin.tenants.metrics(id:)` — item / blob counts + recent activity.
  - `client.admin.tenants.keys(id:)` — active key listing for a tenant.
  - `client.admin.tenants.quotas.get(id:)` / `set(id:_:)` — per-tenant quota read/write.
  - `client.admin.accountDeletion.purgeNow()` — force a one-shot run of the pending-delete purger.
- **`client.auth.account`** — post-sign-in account-lifecycle endpoints. Distinct from `MarfaAuth` / `Passkey` / `DeviceFlow` which run the sign-in ceremony.
  - `client.auth.account.requestDelete()` — initiate deletion (mints token + dispatches confirmation email).
  - `client.auth.account.confirmDelete(token:)` — programmatic equivalent of the confirmation-email link.
  - `client.auth.account.cancel()` — cancel an in-flight deletion.
- **`client.items.createWithAttachments(_:)`** — atomic host + attachment(s) write. Uploads every attachment's blob concurrently, then issues one `items.bulk` call with `mode: .createOnly` and `atomic: true`, and hydrates the host + attachments via per-id reads. Auto-edges from each attachment back to the host (default `attached-to`; configurable via `edgeType`). Caller-supplied edges merge additively. Throws annotated `MarfaError`s on per-step failure.
- **`source_id` on item updates** (server v5.5.0) — `UpdateOptions.sourceId` and the underlying `UpdateItemBody.source_id` field. Renames the natural key under the item's `source`; server enforces `(source, source_id)` uniqueness with a fresh `source_id_conflict` 409 code (separate from the existing version-conflict path). Travels through the mutation queue + replay for synced-mode callers.
- **SSE decode-failure logging.** Malformed SSE events now log on the `sync` category (`sync.sse.decode_failed event=... type=... reason=...`) rather than silently dropping via `try?`. Closes the "stream open, no events applied" invisible-failure mode.
- **Structured `lastError` on dropped mutations.** `SyncEngine` formats the failing `MarfaError` into `code=... status=... message=... details={...}` rather than calling `error.localizedDescription`, preserving the structured code / status / details for downstream surfaces.

### Changed

- **OpenAPI snapshot refreshed** to the updated monorepo spec. Only the three already-generated `ConflictResponse` / `ConflictSnapshot` / `MergePolicy` headers change (`anyOf/0` pointer redirect); all 28 wire types and 22 domain models regenerate byte-identical.

### Breaking

- **DeviceFlow parameter rename** — `DeviceFlow.start(...)` and `DeviceFlowHandle` carry the testability seams (`DeviceFlowHTTPClient`, `DeviceFlowClock`) that shipped on main after v7.0.0. Callers depending on the older signature need to update; default-arg overloads cover the common case.

### Internal

- **These changes already shipped to `main`** and are tagged here so consumer-app builds can pick them up.

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
  original payload, the dropping `MarfaError` shape (status / code /
  message capped at 1024 chars / details JSON), the original
  enqueue timestamp, and the drop timestamp.
- **`DroppedMutationRecord` Sendable DTO + `MutationQueue.fetchDropped()`.**
  Returns every dropped row, newest first.
- **`MarfaStore.queryDroppedMutations()`** vending
  `DroppedMutationsQuery` (`@Observable @MainActor`). Refreshes on
  the same `ModelContext.didSave` + 50 ms debounce as every other
  reactive query. Returns `nil` for clients without a sync engine.
- **Dismissal APIs on `MarfaStore`** (forwarding to `MutationQueue`):
  - `store.dismissDropped(id:)` — single row.
  - `store.dismissDroppedOlderThan(_:)` — strictly less-than the
    cutoff. Lets long-running apps clear stale rows without the SDK
    committing to an opinionated retention default.
  - `store.dismissAllDropped()` — clears the table.
- **First on-disk migration test in the repo.**
  `SchemaMigrationTests` writes a V1 store, closes the container,
  reopens via `MarfaModelContainer.make` (which uses the V2
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
- The drop-and-recreate fallback in `MarfaModelContainer.make` is
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
- **`MarfaStore.queryFullSyncState()`** vending `FullSyncStateQuery`
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
(`MarfaModelContainer.make` deletes and reopens on schema mismatch).

### Changed

- **`Item.library: Bool` → `Item.tier: String`.** Tier-axis rename
  with a new persisted field shape (`feed` / `vault`).
- **New `SchemaVersionMismatchError` (`MarfaError` subclass).** Surfaces
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
  per-item badges, queue visualizations, retry banners.
  `hasPendingMutations` is unchanged for consumer-app compatibility.
- **`BlobUploadProgressQuery` reactive surface.** Vended via
  `store.queryBlobUploadProgress()` (returns `nil` for network-only
  clients). Tracks per-hash `BlobUploadProgress` entries with `state:
  BlobUploadState` (`.pending` / `.uploading(bytesUploaded:totalBytes:)`
  / `.completed` / `.failed(MarfaError)`). Entries are evicted from
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
  callback.** Direct-mode callers (network-only `MarfaClient`) can
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
  verified present.** Follow-up to an earlier suspicion that
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
  `@withmarfa/sdk` 3.8.0.
- Cross-batch atomicity does NOT hold for the `bulkAll` helpers.
  Each batch's `atomic` guarantee stops at its own transaction —
  callers relying on strict all-or-nothing semantics for a run larger
  than one batch need to reconcile failures out-of-band.

## [4.2.2] — 2026-04-24

Defensive bug fix. `TypesNamespace`, `KeysNamespace`, and
`WebhooksNamespace` previously hit the transport unconditionally. On a
pure-local client (`MarfaClient.local(path:)` or the iCloud-mode
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
one-liner path off the file-backed `MarfaClient.local(path: <uuid>)`
pattern that was crashing later tests in the same process with
`"Failed to cast model MarfaSDK.MarfaItemModel… to MarfaItemModel"`.

### Added
- **`MarfaSDKTest.makeInMemoryClient()`** — builds a pure-local
  ``MarfaClient`` backed by a fresh in-memory `ModelContainer`. Drop-in
  replacement for `MarfaClient.local(path: <uuid>)` in test setups.
- **Consumer-app test-setup guidance** in
  `Sources/MarfaSDK/LocalStore/README.md`.

### Notes
- The most plausible root cause of the crash is XCTest host-bundle
  linkage loading two distinct `MarfaSDK.MarfaItemModel` class pointers
  into the same process — the persistent-store code path is where that
  ambiguity surfaces. In-memory containers sidestep the persistent
  stack entirely. No SDK runtime change was made; this is a
  test-support and docs release.
- `MarfaSDKTestSupport` is explicitly non-semver-stable across SDK
  minor versions. The helper is additive and safe to adopt immediately.

## [4.2.0] — 2026-04-23

Opens the SwiftData container up for caller-controlled CloudKit
mirroring. Consumers that want iCloud sync can now build a container
with `cloudKitDatabase: .automatic(containerIdentifier: …)` and pass it
straight to `MarfaClient`. The pure-local convenience path is unchanged.

### Added
- **`MarfaClient.local(container:)`** — new public async factory taking a
  caller-built `ModelContainer`. This is the low-level entry point; use
  it when you need to configure the container directly (for example,
  to opt into CloudKit mirroring). `MarfaClient.local(path:)` remains
  and is now a convenience that delegates to it.
- **`cloudKitDatabase:` parameter on `MarfaModelContainer.make`.**
  Defaults to `.none` so existing call sites are unaffected. Pass
  `.automatic(containerIdentifier: "iCloud.…")` to turn on CloudKit
  mirroring. In-memory containers ignore the argument — mirroring
  requires a persistent store.

### Changed
- **`MarfaModelContainer` is now fully public** (previously
  `@_spi(MarfaSDKTestSupport) public`). Consumers need direct access to
  build containers with custom CloudKit configuration before handing
  them to `MarfaClient.local(container:)`.
- **`scripts/cloudkit-smoke`** now uses the public
  `MarfaModelContainer.make(path:cloudKitDatabase:)` API instead of
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
- **SwiftData `@Model` schema** (`Sources/MarfaSDK/LocalStore/Schema/V1/`) — six models (item, edge, metadata, pending mutation, sync state, pending blob). CloudKit-compatible from day one: no `#Unique`, all properties defaulted, all relationships optional with explicit inverse on one side, no `.deny` rules, Codable enums persist via their `String` rawValue.
- **`MarfaModelContainer.make(path:)`** — single construction entry point. Exposed via `@_spi(MarfaSDKTestSupport)` so test targets can build in-memory containers without leaking the constructor into the public surface.
- **`MarfaSDKTestSupport.MarfaSDKTest`** — `makeInMemoryContainer()`, `makeInMemoryLocalStore()`, `makeInMemoryStorePair()`, `waitForRefetch(after:)` helpers so tests match the production actor-construction path (`Task.detached` off-main).
- **`PredicateConventions.swift`** — documents the SwiftData predicate-safe subset every fetch and reactive refetch sticks to. `Tests/MarfaSDKTests/PredicateSafetyTests.swift` regresses every supported predicate shape so a refactor can't silently drift off it.
- **`cloudkit-smoke` executable** — manual pre-tag schema validation against a developer's CloudKit container (`MARFA_CK_CONTAINER` env var). Not in CI (GitHub runners don't carry CloudKit entitlements). See `Sources/MarfaSDK/LocalStore/README.md`.
- **`RefreshDebounce.interval`** — single constant (50 ms) tuning the reactive debounce window across all seven query types.

### Changed
- **Factories moved to `async throws`.** `MarfaClient.local(_:)` and `MarfaClient.synced(...)` construct their actors via `Task.detached` so the synthesized `@ModelActor` init doesn't bind to `@MainActor`. Every call site updates `try` → `try await`.
- **`LocalStore` and `MutationQueue` are `@ModelActor`s** sharing one `ModelContainer`. Public method signatures preserved. Wire types (`Item`, `Edge`, `Metadata`) cross actor boundaries; `@Model` instances never do (mapped via `Schema/V1/Mappers.swift`).
- **`PendingMutationRecord` is a Sendable Codable DTO** (not a GRDB `PersistableRecord`). The `SyncEngine` and the rewrite/cascade logic operate on records, not models. Shape is byte-for-byte the legacy struct.
- **Reactive queries rebuilt on `ModelContext.didSave`** + 50 ms debounce + refetch. Every query type listens via `NotificationCenter.notifications(named:)` (an async sequence — no observer-token leak), runs the refetch on `@MainActor`. Public API of the seven query types (`ItemQuery`, `TypedItemQuery`, `SingleItemQuery`, `EdgesQuery`, `BackrefsQuery`, `TagsQuery`, `ItemsWithMetadataQuery`) unchanged.
- **`TagsQuery` aggregation moved to Swift.** The legacy `SELECT … FROM json_each(tags_json)` raw SQL is replaced by a single fetch with `relationshipKeyPathsForPrefetching = [\.item]` and bucketing in Swift. Same canonical ordering (count DESC, tag ASC).
- **Three atomicity guarantees preserved as single `modelContext.save()` calls:** `enqueueBlobUpload` (blob row + mutation row), `purgeItem` (item + cascade metadata), `dropMutationsReferencingLocalId` (three fetch passes, all deletes in one commit).
- **Platform minimums bumped** to iOS 26 / macOS 26 / visionOS 26 / watchOS 26 / tvOS 26. Required for the iOS-26-era SwiftData APIs the SDK uses (`#Index`, relationship-prefetching hints).
- **`PendingBlobModel.hash` renamed to `contentHash`.** The legacy name conflicts with `Hashable.hash(into:)` and triggers an `__NSCFNumber` → `NSString` cast crash inside SwiftData's runtime metadata pipeline on save. Wire payload still serializes `hash` (in `UploadBlobPayload`); only the `@Model` property moved.
- **Predicate convention rule 1 amended.** `String.isEmpty` (and its negation) silently match every row under current SwiftData. The SDK uses explicit `prop != ""` comparisons everywhere; `PredicateConventions.swift` and the regression test reflect this.

### Removed
- **GRDB dependency.** Dropped from `Package.swift`; `import GRDB` removed from every source file.
- **`LocalStoreRecords.swift`.** `ItemRecord` / `EdgeRecord` / `MetadataRecord` are obsolete under SwiftData. `LocalStoreError` moved to its own file.
- **WAL-mode / `DatabasePool` / `ValueObservation`** — replaced by SwiftData's built-in container management and change notifications.

### Migration notes

- **No automatic migration from pre-4.0 stores.** Any on-disk store from SDK 3.x or earlier is incompatible with the new schema. Consumers must delete and recreate their stores on upgrade. The SDK is pre-release; no external users depend on automatic migration.
- **CloudKit sync is unlocked but not enabled.** `cloudKitDatabase: .none` in 4.0. Phase 2 (consumer app's iCloud sync work) flips this to `.automatic` against the app's ubiquity container. The schema is already validated for CloudKit compatibility via `cloudkit-smoke`.
- **Every namespace API is unchanged.** Items, Metadata, Extensions, Edges, Blobs, Types, Keys, Webhooks — same methods, same parameters, same return types. Only `MarfaClient.local(_:)` and `MarfaClient.synced(...)` need a `try await` at the call site.

[4.2.0]: https://github.com/withmarfa/swift-sdk/releases/tag/4.2.0
[4.1.0]: https://github.com/withmarfa/swift-sdk/releases/tag/4.1.0
[4.0.0]: https://github.com/withmarfa/swift-sdk/releases/tag/4.0.0
