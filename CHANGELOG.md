# Changelog

All notable changes to the Swift SDK are documented here.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`MarfaStore.queryTypesInData()` answers which item types a store actually holds.** No route returns this, no server aggregate exists, and it has to work offline, so walking the item rows is the only way to know it. What makes the walk affordable is what it declines to do: it reads one column and never calls `toWireItem()`, so no `propertiesData` blob is JSON-decoded — the same trade `TagsQuery` already makes. The alternative a consumer reaches for is an unfiltered `ItemsWithMetadataQuery` plus a walk over `item.type`, which materializes and decodes the entire library on every store save to answer a question about a filter menu; an app shipped exactly that. Trashed rows are excluded, which is a deliberate divergence from that unfiltered walk: a type whose only items are in the trash is not a type the space holds, and `TagsQuery` already excluded them, so a consumer building one filter list from both had the type of a trashed item offered while its tags were not.

- **`OAuthDiscovery.issuer(forServer:)` derives the OAuth issuer identifier from a Marfa server URL.** A Marfa deployment mounts its authorization server under `/auth` and publishes `https://<host>/auth` as its issuer, so a bare server URL is not an issuer and RFC 8414 §3.3 refuses a document that names one against a request for the other. Every consumer of this SDK had assumed otherwise, and the uniformity is the point rather than a coincidence: two apps, both written against these docstrings, both passing the server URL to a parameter called `issuer`, both with sign-in dead for weeks. The derivation now has one documented home instead of being knowledge each app was expected to have. The parameter still takes the issuer — deriving it inside the flows, so the wrong value becomes unrepresentable rather than merely avoidable, is the right end state and is a breaking change with a rename attached, so it is not this release.

### Fixed

- **`OAuthDiscoveryError` reached consumers as a case index rather than as a sentence.** The type carried a `CustomStringConvertible` description naming both issuers in plain text and did not conform to `LocalizedError`, so `localizedDescription` fell through to the NSError bridge and rendered every case as "The operation couldn't be completed. (MarfaSDK.OAuthDiscoveryError error 3.)". A consumer showing `localizedDescription`, which is what a SwiftUI error row shows, therefore had no route to the description at all. That is not a cosmetic gap: it is what turned a one-line issuer mismatch in a consumer app into an afternoon of reading discovery code, the server's published metadata and RFC 8414 side by side. `OAuthIssuerValidationError` gets the same treatment — it is internal, but `MarfaAuth.signIn`, `MarfaAuth.restore` and `DeviceFlow.start` all throw it out through public API, so a consumer only ever sees it through `localizedDescription` too.

- **The `MarfaAuth` and `DeviceFlow` docstring examples showed a value that cannot work.** Both opened with `issuer: URL(string: "https://staging.marfa.so")!`, which fails at the first discovery call against any Marfa server, and both then built a `MarfaClient` from `auth.issuer` / `handle.issuer`. The second line is wrong in the other direction once the first is corrected: an issuer carrying `/auth` points the API client at the authorization server. The examples now hold the server URL and derive the issuer from it, which shows the distinction rather than describing it. `Passkey.enroll(issuer:)` is documented as the wart it is: its parameter genuinely means the server URL, so one label now means two things across three entry points, and it wants renaming to `serverURL` in a release that can break source.

## [14.0.0] — 2026-08-26

**Major because `ConnectionUninstallResult`'s memberwise initializer gains a
required `upstreamCredential` parameter**, so an existing
`ConnectionUninstallResult(...)` stops compiling. That is the only
source-breaking change in this release; everything else is a fix. Decoding is
unaffected, and in practice the callers are tests seeding `MockTransport`
through `MarfaSDKTestSupport`.

### Added

- **`ConnectionUninstallResult.upstreamCredential`.** The server has returned it as a required field for some time and the snapshot this package generates from had not been refreshed since before it landed, so it decoded away. Non-optional, matching the contract. `connections.uninstall` documents how to read it: the spec declares it as an unnamed union, so it arrives as a free-form map discriminated on `status`, with `retained` naming the other connections that kept the upstream credential alive.
- **`SpaceConfig.activityRetentionDays`** and **`SpaceConfig.maxEventHopBudget`.** The platform's space configuration carries six fields and this model declared four, so the two missing ones decoded away silently. That matters more than an absent accessor: `PUT /spaces/me/config` is a full replacement, so the ordinary read, change one value, write it back sequence sent back a document with both keys gone and erased whatever the space had set, reporting a successful write. `activity_retention_days` has been settable since activity retention shipped, so this was reachable rather than theoretical.

### Changed

- **`ConnectionUninstallResult`'s memberwise initializer takes `upstreamCredential`, and it is source-breaking.** The parameter has no default because the field is required on the wire and there is no honest value to default it to, so an existing `ConnectionUninstallResult(...)` stops compiling. In practice that means tests seeding `MockTransport` through `MarfaSDKTestSupport`, which is a shipped product and exists precisely so consumers can construct response types. Decoding is unaffected. **This makes the next release major.** The 12.3.0 note records the rule this fails: a minor is what an added field earns when its initializer parameter is defaulted and existing call sites compile unchanged.

### Fixed

- **`ConflictStrategy` documented the opposite of what a replay does.** It said `.callback` degrades to `.auto` on replay because the closure is not available. `SyncEngine` deliberately does not do that and says so in its own comment, and `ConflictResolverRegistry` agrees that nothing here silently substitutes one strategy for another: a replayed `.callback` runs the resolver registered on the client, and throws if there is none. The false sentence was the public-facing one, which is the one a consumer reads. It is very likely what produced a real defect: an app passed `resolve:` per call, never registered a client-level resolver, and every edit to an existing note then failed to replay indefinitely — exactly the conclusion that sentence invites. Documentation only; no behavior changed.
- **A local date range meant a different date than the same range against the server.** `since` and `until` compared `updatedAt` here; the server compares `COALESCE(timestamp, created_at)`. So the identical filter selected on when an item was last edited locally and on the date the item is actually about remotely, and a consumer app drawing `timestamp` on its cards showed a third answer again: choosing "today" returned items edited today on rows dated months earlier, while running the same filter through search returned a different set. Now matched. The comparison is split across two places for a reason worth knowing: SQL narrows on `timestamp` and deliberately lets rows carrying no timestamp through, and those few are settled against `createdAt` afterwards. Naming both columns twice inside `#Predicate` pushes the type-checker past what it accepts, and that predicate is shared with every reactive query. Permissive rather than strict in SQL on purpose, since a row wrongly excluded there cannot be recovered later while one wrongly included costs nothing to drop.
- **A local list ignored the `tags` and `tier` it was filtered on.** `makeItemsDescriptor` applied `type`, `state`, `since`, `until`, `limit` and the sort, and silently dropped everything else it was handed. A caller passing `tags:` got no error and got every row, which is indistinguishable from a filter that matched everything. `LocalStoreSearch` honoured both correctly, so search and browse disagreed about what the same filter meant, and only the search path documented any divergence. In a consumer app this was why a conflicted-copies recovery filter set itself, showed as active, and changed nothing on screen. `tier` is a plain column and now narrows in the predicate. `tags` cannot: they live in `MarfaMetadataModel.tagsData`, a blob the predicate engine cannot see into, so they are applied after a metadata join with AND semantics, matching the server. Both reactive item queries and the with-metadata query now go through the same selector, so they narrow identically rather than each reimplementing part of it. What a local list still does not narrow on — `source`, `filter`, `edge`, `backref` — is now written down on the descriptor rather than left to be discovered the same way.
- **A tag-filtered local page is windowed over the filtered rows, not the raw ones.** Applying a limit before a filter that runs after the join would hand back a short page and report it as a complete one, which is the same defect in a different place. A tag-filtered list therefore walks its candidate set, which is the trade `LocalStoreSearch` already makes and states; without tags the descriptor windows as before and nothing gets slower.
- **A local page that truncated reported that it had not.** `LocalStore` applied a caller's `limit` and then returned `hasMore: false` with no cursor, on items and on all three edge listings. To a caller that reads as "that was all of them", so the ordinary paging loop — fetch a page, append, stop when there is no more — silently kept the first page and discarded the rest. A consumer app hit this migrating a local library to a server: it paged at 500, believed the first page was the whole store, and uploaded 500 of roughly 1,300 items, one way, with no error. The same defect ended `client.items.all(filters:)` after one page on a local client, since `PaginatedSequence` terminates on exactly that signal. Pages now over-fetch by one row to learn whether anything was left behind, report `hasMore` truthfully, and carry a cursor that reaches the rest.
- **Local cursors are offset-based, and that is a deliberate divergence from the server.** The server keysets over `(sort value, id)`, which is the better contract because it survives writes landing between pages, and it was implemented here first for exactly that reason. It does not survive the compiler: expressing the boundary inside `#Predicate` means naming a sort column and both directions, and the macro pushes the type-checker past what it accepts. That predicate is shared by every reactive query, so it is the wrong place to spend the budget. The cost is bounded and worth stating: a caller paging a local store *while it is being written to* can miss a row or see one twice; a caller paging a quiescent store — an export, a migration, an enumeration on a client that is not syncing — gets exactly the right rows. Local and server cursors do not decode as each other, and a cursor from the wrong side is now refused with a `ValidationError` rather than read as "start again", which would page forever. Items also gained an `id` tiebreak on the sort so a page boundary is deterministic rather than whatever order the store felt like.
- **`items.listWithMetadata` returned a local page shuffled, and threw away the pagination it had just been handed.** It fetched the page, then spawned one metadata read per item in a task group and collected them as they completed, so the order the caller sorted by was lost — and it then rebuilt the envelope with `cursor: nil, hasMore: false`, re-swallowing the truncation signal. It now goes through one store call that pairs an already-ordered page with its metadata in a single further read, so the sort survives, the cursor survives, and the N+1 is gone.
- **The OpenAPI snapshot this package generates from was stale**, which is why the above went unnoticed. The codegen freshness check compares the generated types against the committed snapshot rather than against the platform, so a snapshot behind the server passes. Both declare the same `info.version`, so nothing signaled it either. Refreshed, which is also what brought `upstream_credential` in. Two other changes came with it and neither needed SDK work: `POST /admin/spaces/{id}/delete` now exists and this package does not wrap it yet, and `PUT /spaces/me/config` now rejects an unrecognized key instead of ignoring it. That last one is worth not mistaking for a backstop against the bug above: it catches a key spelled wrong, not a key left out.
- **The codegen freshness job had not run since it was last edited.** Its toolchain step carried a truncated copy of the one in the build job: an `if` opened and never closed, so the step failed on a bash syntax error before reaching `swift run codegen-wire`. The job is main-only, so the failure was somewhere nobody was looking, and the check that would have caught the stale snapshot above was itself off. Both jobs now share one copy of that step as a composite action, because keeping two was the defect. A composite step has to name its shell, and naming `bash` turns on `pipefail`, which an inline step does not get; the two greps that answer "no Xcode here" and "this Swift is unfamiliar" with an empty string say so explicitly rather than relying on it being off.
- **`SpaceConfig.Enforcement.sourceFilter`'s documentation described the opposite lever.** It said the listed sources were blocked from writing the listed types, and called it the inverse of `sourceAllowlist`. It is a read-side predicate and the listed sources are the approved ones. An operator following the old text to stop an importer would have hidden every item of those types from every other source instead.
- **A hand-written wire model can no longer quietly fall behind the spec.** The round-trip suite proves a model does not drop a key it was given, which says nothing about a key the fixture never carried, and that is the shape the `SpaceConfig` bug had. A new check reads the committed OpenAPI snapshot and asserts the fixture's field set matches it at every depth the snapshot spells out inline, so refreshing the snapshot fails until the fixture gains the field and then fails the round-trip until the model does. Recursive rather than one level deep, because a shallow check leaves the identical bug reachable inside `enforcement.source_filter`. A `$ref`, a `oneOf` or a free-form map declares no single field set, so the walk stops there rather than comparing against a guess; none appears at this path today. It fires on a refresh, not on staleness: a snapshot nobody refreshes is still unguarded, and closing that needs a scheduled job diffing against a live server.

## [13.0.1] — 2026-08-23

### Fixed

- **The `.callback` refusal on a local-only client now describes that client.** A `.callback` update with no resolver is refused at the call site, which is right, but the refusal called the client synced-mode and told the caller to register a resolver with `registerConflictResolver(_:)`. That method installs nothing on a local-only client, so following the advice produced the identical refusal with nothing to explain why. A local-only client never syncs, so no conflict can arise there and no resolver would ever run; the refusal now says exactly that, and points at `.auto`, `.manual`, or a per-call `resolve:` for code that also runs against a synced client. `registerConflictResolver(_:)` documents its inertness on both queueless clients rather than only on the direct one. Message text only; no behavior changed.
- **`TypeSchema.roles` decodes to a value.** The 13.0.0 note said the server populated it for no type, which was true when written and is not now. Both `GET /types` and `GET /types/{id}` return the field, resolved through the inheritance chain, so a subtype of a container decodes as a container. No SDK change was needed; the caveat published with 13.0.0 no longer applies.

## [13.0.0] — 2026-08-21

### Removed

- **`Integration.runtimeCompatibility`.** The manifest contract dropped the field it mirrored. It listed the runtime substrates an integration supported, from a time when the in-process runtime sat beside a separate Workers one; that substrate was retired, which left a required field whose only remaining value meant "runs on the Marfa runtime" — true of every integration. Removed rather than renamed, because a rename would have preserved a distinction that had stopped existing. This snapshot was the last published surface still declaring it.
- **`ConnectionUninstallResult.schedulesDisarmed`** and **`.scheduleDisarmError`.** The server had already stopped returning them, so both had been decoding to their defaults rather than to anything real.

### Added

- **`Connection.mapping`.** `system.connection` has carried this since per-connection user mappings shipped, and this model never read it, so a field the platform declares was invisible to every client. Opaque for the same reason `configuration` is: the platform validates it as a whole document at `PUT /connections/{id}/mapping`, and its shape belongs to the shared mapping module rather than to the connection's own schema.
- **`TypeSchema.roles`**, an optional array with a `container` case. A type declares itself a container to accept members through the containment edge, which replaced a fixed list of type names. Note the server does not currently populate this for any type, so it decodes as `nil` even for types that declare the role; that is a server defect rather than a contract one.

## [12.5.0] — 2026-08-19

### Added

- **`ConflictData.itemId`.** The payload a conflict resolver receives described the collision and nothing about what collided. A per-call resolver did not need it, because the call site had just passed the id; a registered one has no call site, and a registered one is the only kind a replayed `.callback` update can reach. So the resolver that most needs to report was the one that could not: it could merge, but an app had nothing to name in a message to a person. The id is now on both the immediate and the replay path. Additive on a struct the SDK constructs and an app only reads.
- **`MarfaSDKTest.makeConflictData(...)`** in `MarfaSDKTestSupport`. A registered resolver is the app's own code, and the only way to run it was to make a real server conflict on demand — so the resolver an app installs was the piece nobody could test. This builds the payload directly.
- **`mediaUrl` and `mimeType` on `CoreMediaEpisode`, `CoreMediaFilm` and `CoreMediaSong`.** The media types could describe everything about an episode except the episode: the only addresses were `url`, which is the web page about the work, and `imageUrl`. `mediaUrl` is the file itself, and `mimeType` says what it is. Marfa stores the address rather than the bytes; `CoreFileAudio` remains the model for content actually uploaded.

### Changed

- **`medium` and `status` carry a closed set of values.** They were free text where the documentation described a fixed list, so nothing stopped two writers spelling `podcast` differently and splitting a query. The server now rejects a value outside the set, and the generated doc comments name the permitted ones. The Swift property stays `String?` — the domain generator does not emit Swift enums — so this is a server-side tightening a client should be aware of rather than a source change.

## [12.4.1] — 2026-08-13

### Fixed

- **A per-call `resolve:` closure satisfies a synced-mode `.callback` update again.** 12.4.0 refused the call unless a resolver was registered on the client, which broke the documented way of resolving conflicts per call and, in a consumer app, turned every save into a thrown error. The refusal now fires only when there is nothing to call anywhere — no per-call closure and no registered resolver. Registering one is still what a replay needs, and that is what the registry is for.


## [12.4.0] — 2026-08-13

### Added

- **`items.promote(id:)`, `items.reconcile(id:)` and `items.occurrences(from:to:type:)`.** Three server routes had no Swift surface at all, so an Apple app could not promote an item into the library, ask how an item differs from the upstream record mirroring it, or expand a recurring event into dated occurrences. `Occurrence`, `ReconcileMirror`, `ReconcileField` and `ReconcileFieldState` come with them. Occurrences is the one that had become a real gap rather than a theoretical one: `CoreEvent` models recurrence as of 12.3.0, and nothing here could read what it expanded to.
- **`MarfaClient.registerConflictResolver(_:)`.** Installs the resolver a replayed `.callback` conflict runs through. See below for why it exists.
- **`ConnectionStatus` on `Connection`.** The lifecycle status the schema has always declared, and the model never read.

### Fixed

- **A replayed edit reaches the app's conflict resolver.** The `.callback` strategy is a closure, a closure cannot be written to the mutation queue, and replay used to resolve as `.auto` instead — silently, with the app's merge logic never called. In synced mode that is the write where it matters most: the edit that races is almost never the online one, it is the replay against a server the app could not reach at the time. The resolver is now registered on the client, so replay can find it. Nothing substitutes one strategy for another any more: a `.callback` update with no resolver registered is refused at the call site, and a replay that finds none keeps the mutation queued rather than merging it under different rules.

### Changed

- **`system.*` schemas are vendored, and the two hand-written models are checked against them.** They stay hand-written on purpose — the generator emits an enum-typed field as a bare `String?`, and `ConnectionKind`, `ConnectionStatus` and `ActivitySeverity` being closed enums is why these models exist. What was missing is any way to notice drift, since the freshness job cannot see a namespace absent from the snapshot. The schemas are now synced and a test compares each model against the one it mirrors. It found a drift on its first run, which is the `ConnectionStatus` addition above.

## [12.3.0] — 2026-08-12

Minor, not major: the platform refresh this stamps is additive throughout. No generated struct or member was removed, and every new memberwise-init parameter is defaulted, so existing call sites compile unchanged. The media restructure that would have removed domain models — `core.media.tv_episode` renamed to `core.media.episode`, `core.media.podcast` dropped — was already vendored and released in 12.x, so nothing breaks here.

### Added

- **`CoreEvent` carries the scheduling fields `core.event` grew at schema version 2.** `allDay` for an event that occupies whole days and therefore has no instant, `timezone` for the zone its schedule keeps its wall-clock hour in, `endTimezone` for the case where an event ends somewhere it did not start, `recurrence` for RFC 5545 property lines on a series, and `originalStartsAt` for an event that replaces one occurrence of one. All optional, all round-tripped by `toProperties()`.
- **The account timezone on the profile.** `Profile` and `UpdateProfileInput` both carry `timezone`. Reading it needs nothing new, and setting it needs nothing new either: `ProfileNamespace.update` takes the generated input struct directly, so the field is reachable the moment it exists.

### Changed

- The `startsAt`, `endsAt` and `precision` doc comments on `CoreEvent` follow the upstream schema in separating an instant from the zone that anchors its wall-clock hour, and in saying what `precision` does not mean: it narrows an instant that exists rather than declaring the event has none, which is `allDay`'s job.

## [12.2.0] — 2026-08-11

### Added

- **A protocol seam over the local store's writes.** `LocalStoreWriting` covers the five writes the sync engine performs (`upsertItem`, `upsertEdge`, `deleteEdge`, `setMetadata`, `purgeItem`), `SyncEngine` now depends on `any LocalStoreWriting`, and `LocalStore` conforms as the only production implementation. The protocol is public so it sits beside `any Transport` in the same initializer, which also widens those five `LocalStore` methods to `public`. It exists so a test — or a consumer hardening its own sync error handling — can substitute a store whose apply fails on command.

### Changed

- The package enables Swift 6.2's `NonisolatedNonsendingByDefault` upcoming feature on every non-plugin target, so nonisolated async functions run on the caller's actor instead of hopping to the global executor. Tools-version 6.2 alone does not turn this on; the flag does, ahead of it becoming the language-mode default. No API change; the full suite passes under the new semantics.
- The error hierarchy's `@unchecked Sendable` now carries its justification once, at the `open` base class, where it is load-bearing — an external subclass can add mutable state the compiler cannot see. The redundant redeclarations on the `final` subclasses are gone; they inherit the conformance.

### Fixed

- **A refused apply no longer loses the event.** The sync engine stamped its cursor before the local write landed and swallowed apply failures, so an event the store refused was gone for good — the cursor was already past it, and a reconnect would not replay it. The engine now applies first and advances the cursor only on a write that landed. A refused write also ends the stream rather than parking the cursor in front of one event while later events carry it past: the failure surfaces as a `.failed` state plus a structured log line, and a first-event refusal counts toward the reconnect back-off so a wedged store is not met with a fresh stream every second.

## [12.1.3] — 2026-08-01

### Fixed

- **The duplicate-metadata fix made every reader disagree with the writer.** 12.1.2 resolved a duplicate `itemId` to the last row in fetch order, while `fetchMetadata` and `writeMetadata` both take the first under a `fetchLimit` of 1. With a duplicate present, `setMetadata` wrote one row, a detail read returned it, and a list, a search or an `ItemsWithMetadataQuery` rendered the other — permanently, since nothing deduplicates. Fetch order is not recency either: none of these descriptors sorts, so "newest" was a guess. All three readers now take the first row, which is what the writer already did.

## [12.1.2] — 2026-07-31

### Fixed

- **Two metadata rows for one item crashed the readers that index them.** `MarfaMetadataModel` is indexed on `itemId` but carries no `#Unique`, because CloudKit mirroring forbids one, and writes are serialised only within a single `LocalStore` — so two devices setting metadata on the same item leave two rows. `fetchItemsWithMetadata` and `ItemsWithMetadataQuery` both built an `itemId`-keyed dictionary with `uniqueKeysWithValues`, which traps on the duplicate. Local search was fixed in 12.1.0; these two were the same defect and were missed.

## [12.1.1] — 2026-07-31

### Fixed

- `MarfaAuth.clearStoredCredentials` now clears the pre-11.4.0 **pending** account as well as the token one. Only the token account is migrated on restore, so a half-finished authorization can still be sitting under the old spelling when the user signs out — state they asked to be rid of, left behind.

## [12.1.0] — 2026-07-31

### Added

- `MarfaAuth.clearStoredCredentials(issuer:clientId:storage:)` — removes every credential the SDK stores for an issuer and client without needing a token provider, which is the path taken when discovery is unreachable. It exists because the alternative is a consumer rebuilding the storage key by hand: `OAuthIssuer` is internal, the key spelling changed in 11.4.0, and an app still deleting the old one deletes a row the SDK's own migration has already emptied. Nothing fails, and a working credential is left on a device the user believes is signed out. The legacy spelling is cleared too.

### Fixed

- **A sign-out landing during a token refresh could be undone.** `performRefresh` had no cancellation check before it stored, so a 200 arriving after `clear()` wrote the rotated pair back over the credential that had just been deleted, and the next launch came up signed in.
- **The single-flight slot was cleared unconditionally.** A caller whose task had already been replaced wiped its successor's registration on the way out, leaving the next caller to start a second exchange against one refresh token — the reuse the single flight exists to prevent.
- **Auth-event subscribers now register synchronously.** Registration was deferred onto a `Task`, so an event emitted in that gap reached nobody and past events are not replayed. A consumer that took the stream and then read a token could miss the `signedOut` that read produced and sit signed-in with nothing listening.
- **An issuer identifier ending in a slash is usable again.** Both flows canonicalized before calling discovery, and discovery compares the published `issuer` against what the caller asked for — so the slash had been dropped and the document could never match, failing sign-in, restore, revoke and the device flow alike. Canonicalization now applies to storage keys only, which is what it was for.
- **`rawUpload` surfaces auth failures as auth failures.** It lacked the clause `rawRequest` carries, so an `OAuthError` from re-minting the header after a 401 was wrapped in a `NetworkError` — an upload against a dead session read as a connectivity blip and was retried instead of signing the user out.
- **Local search no longer traps on duplicate metadata.** `Dictionary(uniqueKeysWithValues:)` over a table that deliberately carries no `#Unique`, because CloudKit forbids one, crashed on every keystroke once two devices had written metadata for one item concurrently.
- **`Retry-After` is no longer sticky.** One 429 made every later retry on that client sleep at least that long for the rest of its life, including retries that had nothing to do with the rate limit.
- **The device flow no longer force-unwraps a server-supplied `verification_uri`**, and local search checks its limit before doing the work rather than after.

## [12.0.0] — 2026-07-30

### Upgrade note

**One word changed, and it is in the public API.** The platform now calls a
space a space, everywhere, with no aliases and no compatibility shims. Consumers
rename at the call site:

| Before | After |
| --- | --- |
| `client.tenants` | `client.spaces` |
| `TenantsNamespace` | `SpacesNamespace` |
| `TenantConfig`, `TenantQuota` | `SpaceConfig`, `SpaceQuota` |
| `tenantId` on wire and domain types | `spaceId` |

Two consequences are not search-and-replace. The generated memberwise
initialiser lists properties alphabetically, so `spaceId` sorts ahead of
`targetId` where `tenantId` sat behind it: call sites passing arguments
positionally have to follow. And a persisted `Codable` carrying `tenantId`
will not decode into the new shape, so anything stored under the old key is
re-established rather than migrated.

### Changed

- **BREAKING:** the space rename, above. The wire types come from the synced
  spec, so it arrives through codegen rather than by hand.
- Surface the vendored snapshot had fallen behind on reaches the Swift client
  for the first time: `ConnectionUninstallResult` gains `schedulesDisarmed` and
  `scheduleDisarmError`, `ApiKey` gains `expiresAt`, and `Profile` gains
  fields. Real API changes, not rename fallout.

### Fixed

- **A 401 is recovered on every path, not just one.** `rawRequest` had the
  refresh-on-401 recovery and the other two paths did not. `rawUpload` had no
  401 handling at all, which is the attachment path behind blob upload and the
  sync engine, and `eventStream` had none either, making a live subscription
  the one call in the SDK where a rotated credential meant a sign-out rather
  than a retry.
- **`RetryPolicy.none` no longer breaks recovery outright.** The recovery ran
  inside the retry loop and reached its retry with `continue`, so at
  `maxAttempts == 1` the continue left the loop: the refresh token was spent,
  the retry never fired, and the caller got a `NetworkError` for an auth
  failure. Strictly worse than having no recovery, and invisible because no
  test drove the public no-retry policy. A credential correction is now
  bounded by having happened once rather than by the retry budget.
- **A refused credential no longer produces a storm.** Against a server that
  refuses every token, ten requests produced ten token exchanges and twenty API
  calls. A forced refresh that fails now stands the mechanism down until a
  non-401 proves the credential works again, matching the TypeScript SDK.

## [11.4.0] — 2026-07-28

### Upgrade note

Tokens stored against an issuer carrying a path, an explicit port, or a
non-HTTPS scheme are deliberately **not** migrated to the new credential
namespace, so those users sign in once more. Migrating them is precisely the
bug the security fix below closes: the migration read a slot it could not
prove belonged to the caller. Signing in again re-stores the token under the
new, disjoint namespace.


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
