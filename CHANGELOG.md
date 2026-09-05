# Changelog

All notable changes to the Swift SDK are documented here.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **A connection stream taken after the engine stopped waited forever.** `SyncEngine.stop()` stops the connection manager, which finishes every subscriber it is holding at the time. A subscriber arriving afterwards registered into a table nothing would read again: it was handed the current state and then waited on a manager that had already published its last value. `for await` never returned.

  It surfaces as a view that stays alive across a teardown — a status line still iterating while the app tears its client down and rebuilds it. Taking the stream *before* `stop()` always worked, which is the property the code's own documentation described, and is why a gap one line away went unread.

  A stopped manager now hands back a stream that is already finished, and a manager started again publishes again.

### Changed

- **The engine reports itself, which is rule 19 and was the one rule with nothing behind it.** An app had to keep hold of the `ConnectionStateManager` it passed into the synced factory in order to answer "am I online", and had to fetch three arrays and measure them to answer "how much is outstanding". Both are on the client object now.

  **Counts rather than rows.** A status line wants a number, and handing it arrays makes it load every payload to display none of them — so `MutationQueueCounts` reaches the database's own count. Pending, in-flight, blocked and dead-lettered are separate, because "2 waiting" and "2 stuck" mean opposite things to someone who could act. Dead letters are excluded from `outstanding` on purpose: a refusal is finished business, and "1 unsent change" for a write nobody will ever send again tells a person to wait for something that will not happen.

  **Hydration progress against a total the server gave**, not one inferred from pages — a page-based import knows what it has taken and nothing about what is left, so progress derived from pages reaches nine tenths and stays there. The total is asked for **once, and only after the first page says there is more**: an import that fits in one page pays nothing, which is most of them and all the small ones, and the import that needs a progress bar is by definition the one with pages left to pay for it. A space that will not answer reports no progress rather than a wrong number.

  **What the total cannot see, stated rather than found later:** it is a snapshot from before the import began, so a space written to during a fill can push `imported` past it. `fraction` clamps; `imported` stays honest.

- **A request body now encodes to stable bytes, without which an idempotency key made things worse rather than better.** The server fingerprints method, path, credential and **body**, and refuses a key replayed with a different request. Swift's synthesized `Codable` fills a keyed container backed by a dictionary, so the same value could encode as `{"version":1,"properties":{…}}` one time and `{"properties":{…},"version":1}` the next — two different requests as far as the fingerprint is concerned.

  **So a replay of an unchanged write was refused as `idempotency_key_reused`.** That is worse than sending no key at all: unkeyed, a replay after a lost response merely conflicted, and the conflict machinery could settle it. Refused, it cannot succeed however often it is retried. Every keyed door was affected, which is every write door the server keys.

  The transport's encoder now sorts its keys. **Nothing is required of a consumer, and a queue built by an earlier version is fine**: a queued mutation stores a typed payload and the body is encoded fresh at send, so rows already waiting go out under the new ordering. There is no need to drain or discard anything.

  **A custom `Transport` gets none of this.** The protocol is a documented injection point, and a conformer that encodes its own bodies has to sort its own keys or it keeps the defect.

  **Found by a live scenario** that sent one body twice under one key and was told the key had been used for a different request — the server was right and the bytes really had changed. It reproduced roughly one run in three, which is why it survived a suite that had already run green many times.

  `.sortedKeys` is Apple's, documented as locale-sensitive and "subject to change", so it fixes an ordering within a build and a system rather than for all time. That covers a retry of one call and a replay on the same device; it would not cover a row whose first attempt and replay straddled an operating-system update that changed the comparator. Named at the site rather than implied.
- **An offline list no longer shows rows the online one hides.** Omitting `state` at the server excludes trashed rows and keeps archived ones — the parameter's own description says so, and a live read confirms it. The local store applied no state filter at all when none was given, so the same `ListFilters` selected different rows depending on whether the client had a store. An app listing notes offline saw items from the bin that its online view had never shown it, and nothing in the kit disagreed with itself loudly enough to notice.

  **What a consumer may have to change.** If you built a bin view on an unfiltered list plus a client-side "is it trashed" check, it is now empty — pass `state: .trashed`. If you relied on an unfiltered list meaning *every* state, pass the new `ListFilters.includeTrashed`. This reaches the **reactive queries** as well as one-shot reads, which is the likeliest place an app meets it: `ItemQuery`, `TypedItemQuery` and `ItemsWithMetadataQuery` all narrow through the same descriptor, so a live view of a space stops showing rows the moment they are binned. That is the intended behavior and it is also a visible change.

  Naming a state still selects exactly that state, the bin included. A queued bulk action resolves against the same set, which is what its own comment already asked for.

  Found by a live scenario that trashed a row on one device and compared what each side then listed. The behavior was previously described in a test comment as a deliberate asymmetry with search; that was a description of the code rather than a reason, and the two now agree.

- **Every write the server keys now carries an idempotency key, including the two doors that carried none.** A key exists so a write whose response was lost can be replayed without landing twice, and these two bypassed the mechanism rather than declining it. Blob upload is the deliberate exception: `POST /blobs` does not declare the parameter, and the replay tells "already there" from "lost" with a `HEAD` probe instead.

  **A client with no local store sent no key at all.** That door has no queue behind it, but it does have the transport's retry loop, which retries `.timedOut` and `.networkConnectionLost` on any method. The reason recorded for that was that such a request cannot have completed on the server — **which is not true of a timeout**: it means this side stopped waiting, and the server may have committed and lost only the response. Unkeyed, that retry was a second create. A key is now minted per call, so the retries of one call share it and two calls never do.

  **The versioned update sent no key either, and its symptom was worse than a duplicate.** A versioned `items.update` takes the conflict door, which had no key parameter at all. The first attempt moves the version, so a replay after a lost response is refused as a conflict *over the edit that landed* — the caller is told it collided when it succeeded, which teaches it the opposite of what happened. The first attempt is now keyed under the row's own key, and the later ones under keys of their own — see below, because a retry carries a different body by design and a keyed repeat carrying a different body is refused.

  **A rebased retry is keyed by the version it rebases onto**, because its body is a function of the row and that version, so the same situation always produces the same key — which is what the server needs, since it refuses a key replayed with a different request. **A resolver-driven retry is keyed too, but with a freshly minted key rather than a derived one**: a resolver returns whatever it likes, so no derivation could reliably name one request, while a fresh key names this one exactly. That covers the transport's own retry of the attempt and not a later drain, which is more than an unkeyed request gave and is stated rather than implied.

  **`Transport.requestWithConflict` gains an `idempotencyKey` parameter**, so a custom transport conforming to the protocol must add it. There is no default implementation on purpose: one would let a conformer silently drop the key, which is the failure this entry is about.

- **Resolving a conflict is the server's job now, and the on-device three-way merge is gone.** The kit sends `conflict=auto` and the server resolves inside the write's own transaction by the type's merge policy. Two implementations of one rule is what this ends, and they did not agree: the kit's `last_writer_wins` kept the *earlier* write where the server keeps the later one, so two devices editing one field reached different answers depending only on which kit resolved it. The kit also spawned its own `keep_both_copies` sibling through an unkeyed `POST /items`, so a lost response made two siblings.

  **`manual` and `callback` deliberately send nothing.** Both mean the caller resolves, and the route's default for an omitted parameter is already `manual`.

  **A `409` that comes back under `conflict=auto` is one the server could not resolve, not one it declined**, and it now surfaces as `ConflictError` rather than being merged locally. **`.auto` therefore no longer retries a conflict at all**, where it previously retried up to three times with a locally merged body.

  **This release requires a server that implements the `conflict` parameter.** A server ignores a query parameter it does not know, so against an older deployment `conflict=auto` is silently dropped, the `409` envelope comes back, and every conflicted `.auto` write becomes a blocked mutation instead of a merged one. There is no client-side fallback and deliberately so: the fallback was the second implementation this change exists to remove.

- **A write that resolved a conflict now reports what the server did.** `ConflictAutoMergedPayload` is filled from the response's `conflict_resolution` rather than inferred on the device, which matters most for the sibling: **no route says what a write created**, so `conflicted_copy_id` there is the only place a conflicted copy is ever named.

  It reaches an app as `SyncEvent.conflictAutoMerged`, so **synced mode only** — a client with no local store has no engine to emit it, and `items.update` still discards the report. That gap is pre-existing and needs a public-API decision; it is filed rather than changed here. A `.callback` resolution carries no report at all, because the caller resolved and the server merely accepted an ordinary write.

- **A write refused against a version history no longer retains now rebases and goes again.** The server answers `ancestor_unavailable` with the two fields a rebase needs, and the kit threw them away by decoding every `409` as a merge conflict — which fails, because that shape requires an ancestor this one has none of.

  **The visible symptom was not a dead letter; it was a queue row that could never clear.** The row parked as an unresolved conflict, and the remedy that state names — resolve it, then `retry(id:)` — re-sends the same stale version and is refused identically, for as long as anyone retries. Under `.auto` the write now rebases onto the version the server says it holds and retries within the same call, which is what `last_writer_wins` already means. `manual` and `callback` are handed `AncestorUnavailableError` instead, because rebasing under them would apply an edit onto a base the caller never saw.

  `AncestorUnavailableError` carries `current` and `requestedVersion`, and a direct-mode caller gets it as a typed error where it previously got a bare `MarfaError`.

- **The OpenAPI snapshot catches up with the server**, which moves several generated names. Most were already named here by earlier entries; one is a removal that is not the kit's choice.

### Added

- **`SyncStatus`, `MutationQueueCounts` and `HydrationProgress`**, reachable as `MarfaClient.syncStatus` and `SyncEngine.status`.
- **`MarfaClient.connectionState` and `.connectionStateUpdates`**, forwarded from the engine. A client with no engine reports `.offline` and a stream that finishes rather than one that hangs a view awaiting it. **`syncStatus` is `nil` there rather than a zeroed status**, because reporting "0 pending, 0 blocked" claims a state of health nobody measured — an app showing a green tick because it forgot to build a synced client is the failure this prevents. **Both `status` and `syncStatus` throw rather than defaulting when the queue cannot be read**, for the same reason: a store that will not answer is not a store with nothing in it.
- **`SyncEngine.connectionState` and `.connectionStateUpdates`.**
- **`MutationQueueCounts.isSettled` and `.outstanding`**, the two derived answers a status line actually renders.
- **`SyncEvent` gains `hydrationEnded(imported:completed:)`, and an exhaustive switch over it stops compiling.** Reported as the enum for the same reason as the case below it: a consumer whose switch is exhaustive gets a build error, and naming the case alone reads like something they could ignore. It tells a consumer watching the event stream that a first fill has stopped, whether or not it finished. Without it `status` cleared its hydration figures on a failed import and the event stream's last word stayed at the fraction it died on — the two surfaces disagreeing, with the wrong one being the surface a progress bar is built on.
- **`MockTransport.stage(_:for:)` and `IncidentalRouteNeedsStagingError`** in `MarfaSDKTestSupport`. **A consumer's tests can go red on this**, so it is worth the detail: the engine now reads `GET /items/stats` during a multi-page import, and the double's response queue is positional — so answering that read from the queue would hand the engine a response staged for something else. A test that stages responses *and* calls `items.stats()` itself now gets a named refusal telling it to stage the route by path, rather than a silently desynchronized sequence. **Not so for the engine's own read**, which is best-effort and swallows the refusal: an import in such a test reports no progress rather than failing, so a test that expects progress events and does not stage the route sees none. An enqueued error is no longer taken by that read either: on the two `request` overloads the error queue is now consumed with the positional responses rather than ahead of them. `requestWithConflict`, `rawRequest` and `rawUpload` are unchanged and still take an enqueued error first; `eventStream` prefers a queued event sequence over one, as it always has. Nothing reads any of them incidentally.
- **`SyncEvent` gains `hydrationProgress(imported:total:)`, and an exhaustive switch over it stops compiling.** Reported as the enum rather than as the case, for the same reason `storeRecovered` was below: a consumer who added no `default:` meets a build error, and naming the case alone reads like something they could ignore. Emitted once per page rather than per row.
- **`ListFilters.includeTrashed`**, the local equivalent of the server's `state=any`, which a single `ItemState` cannot express. Without it, narrowing the unfiltered default above would have removed a capability rather than corrected one — "every state in one read" was reachable before by passing no filters at all, and a bin view and a resuming client both need it. A named `state` wins over it, because that is the narrower request.

- `AncestorUnavailableError`, plus the `AncestorUnavailableResponse` wire type it decodes from and its nested `AncestorUnavailableResponseError` and `AncestorUnavailableResponseErrorCode`.
- `ConflictResolution`, the server's report of a resolution it performed, reachable through `ConflictAutoMergedPayload`.
- `EdgesNamespace.get(id:)`, wrapping `GET /edges/{id}` — a route the server declares and the kit had no way to reach. It reads the local store when there is one, so an edge already on the device is readable offline.

### Removed

- **The client-side merge and its primitives**: `autoMergeWithPolicy`, `keepBothFlow`, `strategyForField` and `autoMergeLastWriterWins`, together with `ConflictResolutionOutcome`, which described their result. All were internal; no public type changes shape. `conflictedCopyTag` stays — the server still applies that tag, and an app filtering for siblings still wants it.

- **`CreatedKey.expiresAt` is gone, and its initializer loses the parameter.** `POST /keys` stopped declaring `expires_at` in its `201`, and **that is a correction rather than a loss**: an expiry can only be set through a path no route reaches, and the create input cannot carry one, so every key either create door mints has none. The field was always `null` there and could never be anything else — declaring it promised generated clients a property that could not arrive.

  It stays real on the read side, where it means something: `GET /keys` returns stored rows, so an expiry set out of band does reach a caller listing keys. Nothing is lost, but a consumer reading `expiresAt` off a create response has code to remove.

- **A refused write now carries the code the server sent, whatever its status.** A `403` learned this when a suspended space needed telling apart from an ordinary refusal; `400` and `409` already knew it. Everything else stamped `server_error` over the answer, and `401` and `404` stamped their own — so `quota_exceeded` and `rate_limited` were the same thing at `429`, and `blob_too_large`, `compatible_with_violation` and `idempotency_key_reused` were the same thing across `413` and `422`.

  **This was the constraint underneath several other divergences rather than a cosmetic loss.** The dropped-mutation log the documentation promises carries the server's code could not carry one, and the classifier could not tell apart refusals that want opposite handling even where it needed to. `UnauthorizedError` and `NotFoundError` gain a `code` parameter defaulting to their old constants, matching `ForbiddenError`.

  **A `404` is the door most apps will notice, and the changelog argued the case on `429` and `413` without mentioning it.** `DroppedMutationRecord.errorCode` used to read `not_found` for every missing thing and now reads what the server called it — `item_not_found`, `type_not_found`, `edge_not_found`, `blob_not_found` and others. Rows dead-lettered before the upgrade keep the old value, so an app grouping or filtering on that column sees both spellings for one failure. Nothing in the SDK reads it; this is app-facing only.

  `server_error` stays as the fallback for a body that named nothing, which is what it always described honestly. A test now asserts the rule across every status the kit parses, rather than one door at a time — three of these reached it separately and the fourth is only visible when you ask all of them at once.
- **The retry ceiling counts refusals, not attempts nobody could make.** A ceiling exists to stop retrying something that will never succeed, and an attempt that failed because there was no network says nothing about whether the write will succeed — it says the question was never asked. Counting it conflated *we could not ask* with *we asked and were refused*.

  **The consequence was not an edge case.** A device offline for a week exhausted its budget having learned nothing, then blocked on the first real answer it ever received. That is what a commute looks like.

  **A store failure during replay is not a refusal either**, and that is a class the transport-shaped test cannot see. The replay writes to the store *after* a `2xx` — it adopts the row the server returned — so a store that refuses there is a write the server accepted. A store failing for its own environmental reason, a locked device or a full disk, would otherwise spend the entire budget and leave the row blocked as "ran out of retries" for a write the server already holds.

  **`PendingMutationRecord` is `Codable` and gains a non-optional field, so JSON written by an earlier build no longer decodes** — it throws `keyNotFound` for `refusalCount`. Nothing in the SDK persists that type; the salvage sidecar writes its own shape. An app that archived one itself needs a migration or a default.

  **`PendingMutationRecord` gains `refusalCount`, and its initializer changes shape** to take it after `attemptCount`. The two are different quantities that coincided until a device could stay offline that long: `attemptCount` still means attempts *made*, which is what a person means by it and what a consumer displays — showing "5 attempts" for a week offline is telling the truth, and a ceiling firing on it is not.

- **A blocked mutation now says why in its own column**, where the reason used to ride inside `lastError` as a `[blocked:<reason>]` string prefix, stamped in one place and parsed back out in another. Nothing public changes: `PendingMutationRecord.blockedReason` reads the same, and the message it reports no longer needs a prefix stripped off it first.

  The reasoning written at the time was sound — a property on a `@Model` needs a schema version, and one added for this alone would have cost every device a migration to carry a string. It stopped being true: V3 was added after `v16.0.0` and has never shipped, so no device holds a store in that shape.

  **A store written by `16.x` still holds the prefix, and is read through it.** `v16.0.0` ships schema V2, its blocked rows are on devices now, and the V2 to V3 migration adds the column as NULL — so reading the column alone would lose the reason on upgrade, and lose it in the worst direction: a `resolverMissing` row read as `retriesExhausted` stops auto-replaying when a resolver is registered, which is the recovery `16.0.0` advertised, and the raw prefix starts appearing in front of the error text an app shows. A read-only decoder covers those rows, and retrying one scrubs the prefix from its message.

  **The smuggling had a failure the column does not.** An unrecognized token decoded as `retriesExhausted`, so a build meeting a reason written by a newer one was told the row would never recover on its own — a reason that clears itself, like a missing conflict resolver, read as one that does not. The column keeps that fallback deliberately, because an old build must not replay a row forever over a reason it cannot read, but it now applies to a genuinely unknown value rather than to every value the parser mishandled.
- **A space the platform has suspended no longer costs a device its queued work.** The server refuses every write from a suspended space with `403 space_suspended`, the kit treated a 403 as permanent, and a permanent failure is dead-lettered on the first attempt. So a suspension discarded the whole queue: the space came back and the offline work did not.

  **The retention-gap resync had to move with it, and that was the sharper half.** A catch-up refuses to import over a queue that has not drained, because the import overwrites rows with no version check and would clobber the queued edits. Previously a suspension emptied the queue by discarding it, so the import proceeded; now the queue stays, so the import declines — and the `catchup_too_old` handler cleared the event cursor *before* asking. The cursor was gone, the import had not run, and once the suspension lifted the later catch-up returned at its already-imported test without ever filling the hole. **A week-long suspension is exactly the case that outlives a retention window**, so the fix that saved the queue would have traded it for silent, permanent divergence. The cursor is now cleared only after an import actually runs; until then the server refuses the stale cursor again on each reconnect, which looks like a loop and is the retry.

  A suspension is a statement about the *environment* rather than about the write, and it clears with nothing the app or the person can do — the same property that already exempts a `401`, a `429` and a `5xx` from both the permanent set and the retry ceiling. It now joins them, so a queued write waits out a suspension however long it lasts. **Blocking it would have been better than dropping it and still wrong**, because a blocked row waits for somebody to press something and nobody pressed anything to cause a suspension.

- **`MarfaError.spaceSuspendedCode`** is public, so an app that wants to say *why* nothing is syncing does not have to hardcode the string. The SDK models this state now; a `SyncEvent.failed` carries the error and this is what its `code` equals.

- **`ForbiddenError` carries the code the server sent, and its initializer gains a `code` parameter** — `init(message:details:)` becomes `init(code:message:details:)`, with `code` defaulting to `"forbidden"` so existing construction still compiles. A 403 previously collapsed to `forbidden` on the way in, which is what made a suspension unrecognizable downstream. A 400 and a 409 already keep theirs, each with a comment saying why; this is the third door, and the reason is the same: the status says a request was refused and the code says what about it was refused.

- **A local query naming a parent type now finds the rows stored under its subtypes, as the server has always done.** `?type=core.entity` returns `core.entity.person` on the server and returned only `core.entity` on a device — no error, just a short answer, on a filter the caller had every reason to think was understood. Listing and offline search both take the rule, because those are the two places the server applies it and the only two a local store should.

  **A subtree has two roots, not one, and resolving either alone is wrong.** The dotted identifier is a namespace and a type's `parent` is a declared lineage; registration has never required a child's id to start with its parent's, so `user.annotated_note` may declare `core.note` as its parent and sit outside `core.note.*` entirely. Resolving names alone missed it. Resolving declarations alone would break the other half, since nothing declares a parent of `google` yet `google.*` plainly means the Google types. Both halves are now resolved and each is pinned by its own test.

  **The declared half needs the cached graph and is empty without it**, which is the same answer a read gave before a registry existed rather than a wrong one. The namespace half needs nothing and holds on a device that has never reached a server. `core.entity` and `core.entity.*` are synonyms, as they are on the server.

  Descent stops at a dot, so `core.note` does not reach `core.notebook`. **`system` is not `system.*`**, because the server decides its operational-row exclusion from the raw filter string: naming a system type outright opts in to seeing those rows, naming the bare namespace does not.

  **A pattern the server refuses now narrows to nothing rather than to everything.** `GET /items` answers `400` to `?type=*` — everything is a listing with no type at all, and a filter matching every type would slip past the per-type enforcement levers keyed off the parameter. A device cannot answer `400` from inside a fetch descriptor, so `*`, `*.*`, `.*` and a trailing dot come back empty. Different in kind from the server, identical in what a caller sees, and wrong only in the direction that shows too little rather than too much.

- **`ListFilters.since` and `.until` are now `timestampAfter` and `timestampBefore`, and they send the names the server takes.** This is a shipped defect rather than a tidy-up: the server renamed those query parameters and refuses the old ones with a `400` naming their replacement, so **every date-bounded remote read this kit made was refused**, and had been since the rename deployed. `timestamp_after` and `timestamp_before` appeared nowhere in the kit. The same two fields on `BulkActionFilter` are renamed with it.

  Local resolution was unaffected — a client with a store answers a date-filtered read from the store, which is why the defect was invisible where most callers meet it. It bit on every remote path.

  **Why nothing caught it is the more useful half.** The vendored specification snapshot reported the same `info.version` as the live server while declaring neither new name, so a version comparison could not see the drift — **a version string is not a staleness signal**. Route coverage compares routes and the route did not move. The daily drift guard did fire, and had been red for two days. And no test anywhere put a time bound against a real server, so a refusal nobody's tests reach looked exactly like a feature nobody uses. There is now a unit test pinning the emitted parameter names and a live test that sends a bounded read and a deliberately impossible window, so a bound that is dropped fails as loudly as one that is refused.

- **`BulkActionFilter` has explicit `CodingKeys`.** It had none and relied on its Swift property names matching the wire — a coincidence that held only while the two vocabularies agreed, and ended the moment the time bounds were renamed. A type whose encoding depends on that coincidence is one rename away from silence.

- **`ConflictResponseError` gains a `message` and its initializer changes shape**, from `init(code:status:)` to `init(code:message:status:)`. The `409` envelope carries a human-readable message alongside its code, and anything constructing one — a test double, a fake transport — needs the extra argument.

- **The bulk fanout flag is renamed, on every type that carries it.** `BulkInput.emitEvents` becomes `BulkInput.enableFanout`, `BulkActionOptions.emitEvents` becomes `BulkActionOptions.enableFanout`, and `BulkEdgeInput.emitEvents` becomes `BulkEdgeInput.enableFanout`, with each initializer changing shape to match: `BulkInput.init(items:mode:atomic:emitEvents:)` to `BulkInput.init(items:mode:atomic:enableFanout:)`, `BulkActionOptions.init(dryRun:confirm:maxItems:emitEvents:)` to `BulkActionOptions.init(dryRun:confirm:maxItems:enableFanout:)`, and `BulkEdgeInput.init(edges:mode:atomic:emitEvents:)` to `BulkEdgeInput.init(edges:mode:atomic:enableFanout:)`. The labels on `items.bulkAll` and `edges.bulkAll` follow.** This is the second wire rename the refreshed snapshot carried, and it failed in the worse of the two directions: the routes declare no additional properties but do not reject them, so the server **discarded** `emit_events` and defaulted the flag off. A caller asking for webhook fanout on a five-thousand-item backfill got every item created, a correct result envelope, no error — and no webhooks. The old name failed loudly at the server; this one failed silently at the caller.

- **`Edge.init` gains a required `version`.** Anything constructing an `Edge` — a test double, a fake transport — needs the extra argument, the same break `ConflictResponseError` takes above.

- **`Edge` carries a `version`,** which the wire has sent since edges gained one, and the local store now keeps it. A locally created edge starts at 1 and the server's value replaces it on the first echo back. Wire fixtures and the `409` envelope's new `message` field moved with the refreshed snapshot.
- **`performInitialSync` now stops when its caller is cancelled**, where before it ran to completion regardless. A consumer whose `.task {}` goes away no longer waits for an import it has stopped caring about — it throws `CancellationError` and abandons a partial one, which is recoverable: `last_full_sync_at` is not stamped, so the next cycle imports again from the start.

  **One cost is carried rather than hidden.** The import is shared between callers, and a cancelled caller cancels the shared task, so anyone else joined to that same import receives `CancellationError` too. Making the cancel conditional on nobody else waiting was tried and is worse — it protects the joiners and strands the caller, which cannot abandon the shared task any more than they can. Both halves have one fix, and it is a restructure rather than a line, so it is filed rather than folded in here.

- **`ManualDeviceFlowClock.nextSleepRequest` can be cancelled**, and returns the new `ManualDeviceFlowClock.cancelledSleepRequest` sentinel when it is. A test waiting for a sleep that never arrives now fails at its suite's limit instead of hanging the run.

- **`MarfaSDKTestSupport` no longer imports `Testing`.** The polling helper that needed it has moved into the SDK's own test target, where all of its call sites already were. `Testing` is a developer-only library absent from a shipped app's runtime, so a consumer linking this target into an app target rather than a test target was inheriting a dependency for a function it could not call.

- **A bulk action on a client with a local store now refuses before it acts, where three of its refusals used to happen afterwards or not at all.** Each of these applied the action first and objected second, which is the same defect wearing three faces.

  **A purge without its confirmation purged.** `options.confirm == "PURGE"` was enforced only inside `BulkActionInput`'s encoder, which runs when the mutation is queued — after the local fan-out. A synced client therefore purged every matching row locally, threw on the way to the queue, and queued nothing: the caller saw an error and could reasonably conclude nothing had happened, while the rows were gone and only a full re-import would return them. A pure-local client has no queue, so the encoder never ran and **the confirmation was not enforced at all**. It is now checked before any row is read.

  **`maxItems` trimmed where the server refuses.** The server's `max_items` caps the match set *before* a `bulk_cap_exceeded` error — it declines the whole action rather than shrinking it. The local path passed the same number down as a fetch window, so a purge capped at one row purged one arbitrary row of the many that matched, reported `matched: 1` so nothing downstream could tell, and returned success. A caller reaching for a cap is reaching for a brake. It now refuses with `BulkCapExceededError`.

  **A bulk `update_timestamp` on a client with a local store now actually moves the timestamp.** It wrote nowhere and counted every matched row as succeeded, on the reasoning that a replay would carry the change to the server. That reasoning holds in synced mode and fails in pure-local mode, which has no queue and no server — so five hundred rows came back reporting `succeeded: 500` with not one timestamp changed, and nothing later corrected it. `LocalStore` gains the setter it was missing rather than the action being refused.

  **A tag bulk action naming neither `add` nor `remove` is refused**, matching the server's requirement that at least one be non-empty. It used to walk every matched row, change nothing, and count them all as succeeded; a synced replay then met the server's refusal and dead-lettered. An empty `remove` array also slipped past a guard that an empty `add` did not.

  **`maxItems` must be greater than zero**, as the server declares. A zero cap refused every non-empty match and a negative one refused even an empty match, so both sides said no and said it differently.

    **`maxItems` also now has the server's default.** The server caps at `min(max_items ?? 10000, 50000)`, so a caller who sets nothing still has a ceiling; the local side had none. A synced client could therefore act on far more rows than the server would then accept, and the replay's `400` is permanent — so the device applied the action, the server applied none, and the mutation was dead-lettered.

  **`LocalModeUnsupportedError` and `LocalFilterUnsupportedError` now report `isPermanent` as `true`.** Both are `501` and both are final by construction, so a caller looping on `!isPermanent` would have spun for ever. This is an override on each class rather than a widening of the `501` status band, and the distinction matters: a *server* answering 501 is a different question — a route mid-rollout, a proxy — and the queue deliberately treats a 5xx as transient so a write survives it. Widening the band would have turned those into dropped writes.

- **A bulk action on a client with a local store now refuses a `filter` expression instead of acting on every row it could not narrow.** This is a shipped defect rather than a tightening, and it is worth reading in full because the failure was silent and destructive. `items.bulkAction` on a local or synced client resolves its own match set against the store, and the resolution accepted the caller's `filter` and `source` narrowing and then dropped both — a documented limitation of the local list, where an over-wide *read* is corrected by the next read. A bulk action is not a read. It applies an action to everything the resolution returned, and `purge` and `transition` are two of the six actions, so a filter expression naming nothing matched everything and a narrowed purge emptied the store. Nothing reported it: the result came back with `matched` set to the wider count, as though those rows had genuinely matched.

  `filter` is the server's expression grammar and reaches across edges; evaluating it on the device would be a second implementation of a rule the server owns, so it is **refused** with the new `LocalFilterUnsupportedError` rather than approximated. `source` had no such excuse — it is a plain stored column — so it now narrows, both here and on every local list and reactive query that shares the descriptor. **A remote client is unaffected in both cases**: it has no store, so its bulk action goes to the server, which evaluates its own grammar and loses no capability.

  Narrow a local bulk action with `type`, `state`, `source`, `tier`, `tags`, `since` or `until`, or perform it through a client built with `MarfaClient(url:apiKey:)`.

- **A re-import now removes the rows the server no longer has, and a row you have just written survives it.** Until now the import only ever upserted, so a row purged on the server while a device was away lived on that device forever: the row is *absent* from the server rather than changed on it, no event describes an absence, and nothing else ever looked. A person met it as a note they had deleted months earlier still sitting in a list on their iPad. The import now takes the ids it saw as the whole answer and removes the rest.

  **Three things make that safe, and all three are behavior worth knowing**, because each one is a different set of rows that would otherwise be deleted. The import asks for every lifecycle state rather than the default slice, which excludes trashed rows — without that widening, a bin full of rows reads as a server that purged all of them and the device's bin would empty itself on every re-import. It also asks for `system.*` rows, which the same route excludes by default while the event stream that fills the store does not: without that, a re-import would delete every device, connection and activity row the store holds, so `connections.list()` would come back empty against a server that still has all of them, and no later event would correct it. And a row the mutation queue still holds a create for is never removed. That last one is not a theoretical case: the import refuses over a queue that has work in it, but it asks once, before the first page, and the paging that follows spans a whole library. Someone writing a note while theirs downloads lands inside that window, and the row the server has never heard of is exactly the one a prune would otherwise take for a purge.

  **A partial answer is refused rather than pruned against.** A page reporting more results and carrying no cursor to reach them used to end the loop and return normally, which handed the prune a keep-set holding only the pages that had arrived — so every row beyond them was deleted. It now throws the new `InitialSyncError.unresumablePage`, leaving the store untouched for the next cycle to retry. Marfa's own server cannot send that pair; this SDK also talks to self-hosted servers, where it is one implementation's behavior rather than a promise the route makes. `InitialSyncError` therefore gains a case, so an exhaustive switch over it stops compiling.

  Each removed row is announced as `SyncEvent.itemPurged(id:)`. The SwiftData-backed reactive queries update on their own; subscribe only if you hold item ids outside the store.

- **An inbound event no longer overwrites an edit that has not reached the server.** A change arriving from another device replaced the local row with the server's copy, so text someone was still typing disappeared from under them and reappeared a moment later when the queue drained. The engine now recomputes what the device should show from the server's row plus the writes still queued against it, so the local edit stays visible **and** the other device's change to a different field lands in the same frame. Trashing, restoring and transitioning rebase the same way, and `metadata.changed` — which carries an item alongside its sidecar — takes the same path rather than a second answer to the same problem.

  One limit worth knowing: the version check below is skipped for a row the device is holding writes for, because a local edit bumps the stored version and the column is then an optimistic guess rather than a server fact. The queued edit survives regardless; a stale frame can still land in a field that edit does not mention.

- **A local listing no longer returns `system.*` rows, matching what the server does and what local search already did.** These are operational records — devices, connections, activity — and the store holds them because the event stream writes them in. An untyped `items.list()` was returning them interleaved with a person's own items, and `TypesInDataQuery` was offering `system.activity` and `system.connection` as filter-menu entries. A synced device holds far more activity rows than everything else combined, so an untyped list was mostly operational records. Naming a system type outright still returns those rows, which is how `connections.list()` works and why the exclusion is conditional rather than absolute. `items.stats()` still counts every row, deliberately: the server counts them too, and excluding them locally would open a divergence rather than close one.

- **A sync event is no longer published for a frame the store refused.** Item events announced unconditionally, so a stale `item.deleted` — correctly turned away by the version check above, leaving the row active — still handed subscribers `SyncEvent.itemDeleted(id:)` for a row they could still read. Events now describe what the store actually did. `metadata.changed` judges its two halves separately, so a sidecar still lands and still announces when the item half is refused for being behind.

- **An item event older than the row it describes no longer applies.** The apply was unconditional, so a frame arriving behind a newer write put the row back to a state it had already left. Item events now apply only when the version they name is not older than the one stored — "not older" rather than "newer", because a reconnect re-delivers the frame it stopped on and refusing that would drop a write the store never made. The metadata layer is untouched by an item event either way: the server writes metadata through its own layer and announces it as `metadata.changed`.

- **`SyncEvent` gains `itemPurged(id:)`, and an exhaustive switch over it stops compiling.** It is not the same news as `itemDeleted(id:)`, which says a row was trashed and can come back. Nothing will ever correct a copy of a purged row, so a view still holding one is showing something that no longer exists anywhere. It fires for both routes a removal reaches a device by — the server's `item.purged` announcement, and a re-import that finds the row gone.

- **`LocalStoreWriting` gains two requirements**, `LocalStoreWriting.applyServerItem(_:rebasing:)` and `LocalStoreWriting.pruneItems(keeping:protecting:)`, so a type conforming to it directly stops compiling until both are written. There is deliberately no default implementation: one that pruned nothing, or applied without rebasing, would take a conformer's store back to exactly the two defects above with nothing reporting it. `LocalStore` provides both — `LocalStore.applyServerItem(_:rebasing:)` and `LocalStore.pruneItems(keeping:protecting:)` — so an app using the SDK's own store needs no change.

- **`item.purged` is applied rather than ignored.** The server began announcing it and the engine had no case for it, so a client heard that a row was gone for good and kept it anyway. An event type the engine still does not recognize is now logged on the `sync` category rather than dropped in silence — that silence is what let this one sit, because a type nobody had written a case for looked exactly like a type deliberately ignored.

- **A local store this build cannot open is now moved aside rather than deleted, and the app is told.** This changes a shipped behavior and a consumer who has never seen the failure will meet it in the field, so it is worth reading in full. Until now, a store the container refused to attach to was deleted and rebuilt empty, and the deletion's own diagnostic was discarded by a `try?` — so a device silently lost its queued writes, its dead-letter log, its event cursor and the account claim in one step, and permanently orphaned the bytes behind every queued blob upload. Items and edges came back on the next import; none of those five did, and nothing said so.

  The store is now **renamed into a quarantine directory beside it** before anything else happens. A rename needs to know nothing about the file's contents, so it cannot fail for the reason the open failed, and everything after it works against a copy that is already safe. **The rebuild is conditional on that rename succeeding**: a store that cannot be moved aside is not deleted either, and `MarfaModelContainer.make(path:cloudKitDatabase:)` throws the new `LocalStoreError.storeQuarantineFailed(_:)` instead of quietly starting over. A rename that succeeds and a rebuild that then fails throws `LocalStoreError.storeRebuildFailed(quarantineDirectory:reason:)`, which carries the directory rather than only the container's own error — at that point the queue has moved somewhere the app has not been told about, and an error without the address is the one remaining way to lose it. `LocalStoreError` therefore gains two cases, so an exhaustive switch over it stops compiling.

  The quarantined store is then read with **SQLite directly rather than through SwiftData** — the refusal is a model-hash check, so the file is a perfectly readable database and the object-graph layer is the one component guaranteed unable to read it — and the queued mutations, the dead letters, the sync state and the queued blobs' descriptors are written to `recovered-queue.json` inside the quarantine directory. That file is plain JSON with a `format` field and no SDK types in it; a blob's bytes are not copied into it, because they are still in the quarantined store. **Nothing deletes the quarantine directory**, which is deliberate: an app decides when it is finished with it.

- **A store recording a schema version this build does not have is refused rather than opened.** It was written by a newer build, so migrating it forward would mean guessing at a shape nobody has described. It takes the same path as a store that cannot be read at all. One caveat worth knowing: until this release the container was handed a schema built from a model array rather than from a versioned schema, so the version identifier never reached disk and **every existing store on disk records `1.0.0`, including stores written under V2**. That is fixed here, which means the check only begins telling the truth for stores written from this version onward.

- **`SyncEvent` gains `storeRecovered(_:)`, and an exhaustive switch over it stops compiling.** A closed enum gaining a case breaks every switch that enumerates it, which is why this is reported as the enum rather than as the case. It is emitted once by `SyncEngine.start()` — the store is opened long before an engine exists to announce it, so a subscriber who takes `SyncEngine.events` and then calls `start()` receives it there.

- **`SyncEngine.init` takes `storeRecovery:`, defaulted to `nil`.** The full spelling moves from `SyncEngine.init(transport:localStore:mutationQueue:connectionManager:drainDebounceInterval:conflictResolvers:maxReplayAttempts:)` to `SyncEngine.init(transport:localStore:mutationQueue:connectionManager:drainDebounceInterval:conflictResolvers:maxReplayAttempts:storeRecovery:)`. Every existing call site compiles unchanged; both `MarfaClient.synced(...)` factories pass it for you.

### Added

- **A store records which server it belongs to, and refuses to open against another one.** `MarfaClient.synced(...)` claims the origin on first use and compares it on every later open; a mismatch throws the new `StoreIdentityMismatchError`, carrying the axis that disagreed and both values.

  **There is nothing to reconcile, which is why this refuses rather than merging.** A store holds one server's rows, one event cursor and a queue of writes addressed to that server. Opening it against a different origin does not give you a store with two servers' data in it — it gives you one where every later answer overwrites rows that were never the same rows, and a queue that replays somebody's edits at a server that has never heard of them. Nothing afterwards distinguishes that from ordinary drift, so it is caught at the door or not at all.

  **Only a writer claims**, so a read-only client cannot stamp an origin the writer never chose. A store built in local mode is unclaimed and takes whichever origin first opens it, because it has no server until it is given one.

  **Every client compares; only a writer records.** Gating both on the writer lock left a read-only client serving one server's rows through a client configured for another, which is the same failure on the read side. A reader over an unclaimed store correctly leaves it unclaimed.

  **The origin is checked before the store is opened**, and it lives in a file beside the store rather than inside it — because opening runs the migration plan and, for a store this build cannot read, the fail-safe that moves it into quarantine. A check that waited for the store to be open would already have let a client with no business touching it migrate the thing. The cost of a sidecar is that a copy taking the database and not the file looks unclaimed; that is a fail-open, and it is the behaviour from before this existed.

  Two spellings of one server are one origin: a trailing slash, a default port and the case of the **scheme and host** are normalized, since `ClientConfiguration` takes whatever URL a consumer passes. The path is deliberately left alone — it is case-significant, and lowercasing it collapsed `gw.example.com/TenantA` and `gw.example.com/tenanta` into one origin, which is the exact false merge this check exists to prevent arriving through the normalization written to prevent false refusals. Credentials, query and fragment are stripped rather than recorded: this value is written beside the store and interpolated into an error a consumer logs.

  New public types: `StoreIdentityMismatchError` and `StoreIdentityAxis`. **The space and account axes are not here** — both need a credential resolved against the server, where the origin is known offline at the moment it matters. `MarfaClient.storeOwnership(resolvedWith:)` already answers the account question for a consumer that asks.

- **A blob this device already has is readable without the network, and the one it just uploaded is the case that was broken.** The only copy a device held of a blob it had sent was the outbound buffer, and that row is deleted the moment the upload succeeds. So a person could save a picture, watch it sync, and then not open it on a train — every read went back to the network for a file the device had held minutes earlier.

  **A hash is a content address, so a cached copy can never be the wrong answer.** There is no version to be behind and no staleness to reason about, which is what makes a read-through cache correct here rather than merely fast, and why it works with no server at all. `blobs.download(hash:)` on a client with a store now serves what the store holds and writes through what it fetches; on a pure-local client it answers from the cache instead of refusing outright, and refuses only for a hash it has never seen.

  Bytes reach the cache at three points, and the first is the one a person feels: an upload caches at the moment it is made rather than when it reaches the server, a successful upload **moves** its bytes across instead of dropping them, and a download writes through. A blob the server acknowledges under a *different* hash is not cached at all — the local hash was wrong, every reference to it will 404 elsewhere, and caching it would make this one device the only place those bytes resolve.

  **The hash covers the bytes and not the MIME type**, which reaches the cache from three authorities — the uploading caller, the outbound row, the server's `Content-Type` — and agrees between them only by luck. A later write corrects it, so the answer converges on whatever spoke last rather than on whoever arrived first.

  **The cache is bounded and the rule is stated:** least recently used, 256 MB by default, `MarfaClient`'s store evicting oldest-first as it writes. A read moves a row's place in that order, because a file opened every day should outlive one fetched once and never opened again. `lastUsedAt` has millisecond resolution, so rows touched in the same millisecond tie — deliberately left alone, since rows used at the same moment are equally recent.

  **`LocalStore.defaultBlobCacheBytes`** is the bound, public so an app can read what it is. It is not yet settable — an app that wants a different one has nowhere to say so, which is a gap rather than a decision.

  **`LocalStoreWriting` gains `cacheBlob(hash:data:mimeType:)` with no default implementation.** A default was tried and it shadowed the real one: `LocalStore`'s method stopped being chosen as the witness, every call landed on the empty default, and the cache silently held nothing while everything compiled. A conformer that wants no cache writes an empty body and says so.
- **One writer per store.** Nothing enforced this: `MarfaModelContainer`'s creation lock is an in-process `NSLock` around building a container, and `SyncEngine.running` is a per-instance flag. So two clients over one store path — two `MarfaClient.synced(...)` in a process, or an app and a share extension over an App Group container — got two engines, two drains and two event cursors, with nothing anywhere saying so. Half the writes replay twice and the cursors diverge, which no per-statement guard can see.

  `MarfaClient.synced(...)` now takes a writer lock beside the store before opening it, and an engine that does not hold one **does not start**. `MarfaClient.holdsStoreWriteLock` says whether this client may write and `MarfaClient.storeHeldBy` says who has it otherwise — a read-only client still answers reads from the store; its queue is somebody else's to send. Taken before the store is opened, because a store this build cannot read must not be moved aside by a caller that does not hold the write, and the quarantine inside `open` is exactly that move.

  **The right to clear is itself exclusive, and reclaiming an abandoned one was not.** Reading a dead right and then unlinking removes whatever is at that path *now* rather than the thing that was read — the same mistake the lock above documents as the whole difference between one writer and two, a level down. Two callers held the right at once at unmodified timing. The claim is atomic, so the reclaim now asks afterwards whether the file is the one it put there.

  **A right is judged abandoned by age, not by whether its process is alive.** The lock names a process that holds it for as long as the client lives; the right names one inside a critical section of a handful of filesystem calls. So a `.clearing` whose release silently failed named a process still running, was judged held for ever, and made the store permanently read-only with nothing raised. An unparseable one had the same effect, though the main lock already handled that exact condition using the same helper.

  **Clearing a stale lock takes an exclusive right and re-reads the holder under it**, and each half alone was measured racing. Renaming the file aside is atomic, so only one caller moves any given file — but a loser still carrying an earlier read moves the *winner's fresh lock* aside to inspect it, and the path is empty while it does, so a third opener claims cleanly in the gap. Taking the right alone does not close it either: the right is released the moment its holder finishes, so a straggler carrying a read from before that clearing can win the right afterwards and unlink a lock that is now live. Winning the right says nobody else is clearing; it says nothing about the file still being the one you judged dead.

  Measured rather than reasoned: twelve openers over thirty rounds, and the same probe catches each partial version within a few rounds.

  **The takeover of a stale lock is atomic**, and it has to be. Clearing by unlink removes whatever is at the path *now* rather than the dead holder just read, so two openers meeting one stale lock both clear and the second clears the first's fresh claim — both come away as writer, and the first's release is then a no-op because its token no longer matches. The trigger is ordinary: an app and its share extension starting together after a crash left a lockfile behind. Clearing by rename means exactly one caller succeeds and the loser re-reads.

  **A read-only client does not import, and does not open with the fail-safe.** An import is not only reads — it prunes, taking the ids the server returned as the whole answer and removing the rest, which can delete rows the real writer created and has not yet pushed. And `open`'s fail-safe quarantines a store this build cannot read, which is exactly the move a caller without the write must not make on the writer's behalf.

  **The lock is released when the client goes away.** Without that a discarded client held its store's path for the life of the process, so a replacement built over the same path was refused with nothing to release. Cross-process that heals on its own through the staleness check; in-process it does not.

  **A second opener is refused rather than queued**, because a caller can do something useful with a read-only store and nothing at all with a promise that has not settled. A holder that is no longer running is taken over: a crashed engine must not make its own store permanently read-only.

  **The staleness check asks for the holding process's start time first, and falls back to the machine's boot instant.** The order matters: `kern.boottime` is not immovable within one boot — a calendar step or an NTP correction moves it — so an equality test on it, asked first, would declare a live holder dead and hand the caller the takeover path. A start time that still matches is direct evidence the holder is the same process. A process id is not an identity across a restart — the machine reboots, the number is handed out again, and a liveness check answers yes for something unrelated. `KERN_BOOTTIME` is the instant itself rather than `now - uptime`, so every process reads the same number and no tolerance window is needed. `KERN_PROC_PID` closes what a boot instant cannot see, a process id recycled *within* one boot, which a portable interface cannot ask about at all.

  New public types: `StoreWriterLock` and `StoreLockHolder`.

- **Every queued write now carries an `Idempotency-Key`, and a retry carries the same one.** A replay whose response was lost is indistinguishable from one the server never saw: the write happened, the acknowledgement did not, and the next drain sends it again.

  **Creates were already safe and are not what this fixes.** The kit stamps its own id on an item and an edge, and both routes answer a repeat carrying a caller-minted id. What had nothing was every other write door. The sharpest is `PATCH /items/:id`, which applies the edit **and bumps `version`** each time it runs: a lost response there costs one edit two version steps, leaves the device's idea of the version behind the server's, and turns the next ordinary edit into a conflict nobody caused. Transitions, restores, promotes and the edge patch and delete are the same shape.

  **A refused write benefits too, and this is the case the server's own middleware says it exists for.** A `409` is recorded like any other outcome, so a client asking a second time is told what its *first* attempt met. Without that, "somebody else holds this" and "my own earlier write holds this" are the same answer.

  **The property is sameness, not presence.** A key minted at replay time would differ on every attempt, which is worse than none: it tells the server each retry is a new request while looking, from the client, exactly like protection working. The key is minted once when the row is enqueued, stored beside it, and never changed.

  **A conflict-aware update is deliberately *not* keyed, and that is the design rather than a gap.** A key identifies one *request*: the server fingerprints method, path, credential and **body**, and answers a repeat carrying a different body with a `422` instead of a replay. The conflict loop sends a different body on every attempt by design — it re-reads the server's copy, resolves against it and re-sends — and the keep-both path inside it makes a `POST /items` sharing nothing with the parent `PATCH`. A stable key across any of that turns a merge into a refusal. There is therefore **no keyed `requestWithConflict`**, so a conformer cannot acquire one by accident.

  **What that leaves exposed, stated rather than waved past.** The conflict machinery is the recovery for most of it: a lost response means the server moved under this write, which is the case the loop exists for. The residual is a device conflicting with *itself* — a `PATCH` that timed out after the server applied it retries, meets its own version bump as a `409`, and resolves against it. Under the default rule that converges silently. Under a field whose policy is keep-both it spawns a `conflicted-copy` sibling, so a lost response can still produce a duplicate a person sees. Closing that needs a key derived per attempt rather than per row, which is a different mechanism and is tracked separately.

  **A key is only ever stamped on a write.** The wrapper covers a whole replay, and a bulk action posts once and then polls the job with `GET`s through the same transport — keying a read is never right, and there it would be silently total, since the server would answer every poll with the first poll's stored body.

  Every other queued write carries a key, including the metadata, tag and extension doors the server deliberately leaves out because a replace, a merge, a set-add and a delete already repeat harmlessly. Two do not: a **blob upload**, which is addressed by the hash of its own bytes and so already repeats as the same write, and a **bulk action**, which posts through the raw path and is not a door the server keys.

  **`Transport` gains `request(method:path:body:query:idempotencyKey:)`, with a default implementation that drops the key** and forwards to the existing four-argument call. An existing conformer keeps compiling and keeps behaving exactly as it did — and gets no protection against a repeated write, because the server cannot recognize a retry it was never told about. The SDK's `URLSessionTransport` and the bundled `MockTransport` both override; a custom transport should too. `MockTransport.Call` gains `idempotencyKey`, so a test can assert that a retry really is the same request.

  **`PendingMutationRecord` gains `idempotencyKey` and its initializer changes shape**, from `init(id:kind:payloadJson:sourceId:localId:createdAt:attemptCount:lastError:state:blockedReason:)` to the same with `idempotencyKey:` appended. Anything constructing one — a test double, a queue inspector — takes the extra argument, which defaults to `nil`.

  Blob uploads carry no key deliberately: a blob is addressed by the hash of its own bytes, so sending one twice is already the same write.

- **A client with a local store now refuses a write its type forbids, before the write reaches the store or the queue.** The server has always refused these; what it could not do is refuse them at the moment the person made one. A write queued offline and rejected on reconnect fails hours later, to nobody, in a log — and whoever could have fixed it in two seconds has long since moved on.

  **`MarfaClient.typeRegistry()`** is the graph it checks against: the platform types the SDK ships with, merged with this space's own types as `GET /types` last described them, the space winning a collision because its rows were written against its shape. **`MarfaClient.refreshCachedTypes()`** fills that cache and returns how many types it stored. A refresh **replaces** rather than merges, because the route answers with the whole space and a type deleted upstream is absent rather than marked — merging would keep it for ever, and a validator holding a type the space no longer has refuses writes the server would accept.

  **An unknown type is not refused**, and the reason matters more than the behavior: a space's types reach the device through a cache that may never have been filled, and refusing every custom type until it is would make the offline story worse than no validation at all. Such a write still meets the server on drain, where it was always decided.

  **Both write doors are covered.** `create` validates what it was handed; `update` validates the **merge** its patch produces, which is what the server checks and what the row becomes. Validating a patch on its own would refuse almost every legitimate edit, since omitting a required field in a delta does not remove it.

  **The cached graph is resolved before it is used, and `MarfaTypeRegistry.resolved()` is public because that matters to anyone else reading it.** `GET /types` answers with schemas **as declared** — a type carries its own fields and a `parent` id, with nothing inherited folded in, because resolving a whole vocabulary is work a caller who wants one type should pay per type. Two things follow. A custom type would enforce none of its parent's rules; and a cached copy of a *platform* type would overlay the generated, already-flattened one and quietly stop enforcing everything it inherits, universal fields included. Resolution seeds the universal fields, then merges the chain root-first, exactly as the server does.

  **Existing callers should expect this to surface writes that were already invalid.** Nine tests in this repository were building items the server would have refused — a `core.note` with no `body`, a `system.connection` with a `status` outside its enum — and passed only because the local store validated nothing.

- **`Connection.mappingReapplyUntil`**, surfaced by refreshing the vendored type snapshot, which had `system.connection` at schema version 2 while the platform shipped version 3. The drift guard caught the missing accessor as soon as the snapshot moved — the snapshot being stale is what had kept it quiet.

- **The type graph now reaches the device.** A client with a local store accepted any type string and validated nothing, so a write the type forbids was queued, sent, and refused by the server — possibly hours later on a reconnect, long after the person who could have fixed it moved on.

  **`MarfaTypeRegistry`** carries every `core.*` and `system.*` type the platform ships, with each definition's inherited fields already flattened. `MarfaTypeRegistry.platform` is the shipped set; `merging(_:)` layers a space's own types over it, the space winning a collision because its copy is what its rows were written against. It answers three questions: whether one type descends from another, which types a query for a parent should match, and which fields a type's display hints name for offline search.

  **`MarfaTypeRegistry.validate(properties:against:)`** refuses a write the type forbids, throwing **`TypeValidationError`** with every failure rather than the first — the server returns them all, and stopping early would make the local refusal and the remote one disagree about a write neither accepts. **`MarfaTypeDefinition`**, **`MarfaFieldDefinition`** and **`MarfaFieldType`** describe what it checks against.

  **What it checks**: an unknown type, a missing or wrongly-typed required field, a declared field holding something it does not declare, a declared `format` (`url`, `email`, `datetime`, `date`, which the server collapses into the field type), the length of a string and its freedom from NUL bytes, an array's element count, and an enum's permitted values. The two universal fields every type carries — `attachments` and `links` — are checked on every type whether it declares them or not, as the server does. Bounds default to the server's own (100,000 characters, 10,000 elements) and a type may override either.

  **What it deliberately does not do**, stated because a local check advertised as equivalent and merely similar is worse than one whose limits are written down: it mirrors the rules the server applies *by default*. An unknown type is refused, a required field must be present and well-typed, and a declared field must hold what it declares. An undeclared property passes, because the server passes it — strict enforcement is a per-space setting the device does not hold, and a write only strict mode would refuse is still refused on drain. The format checks are narrow in the safe direction: each accepts at least everything the server accepts, so a write the server would take is never refused locally.

- **`LocalFilterUnsupportedError`**, thrown when a narrowing cannot be applied where a request is being resolved, so the request is refused rather than answered wider than it was asked. It carries the `operation` refused and the `field` that could not be applied.

- **`BulkConfirmationRequiredError`** and **`BulkCapExceededError`**, mirroring the server's `bulk_confirmation_required` and `bulk_cap_exceeded` so a caller catches the same failure wherever the action resolved. `BulkCapExceededError` carries the `matched` count and the `cap`.

- **`PendingItemEdit`** describes one unsent write against an item in the form the store needs in order to put it back on top of the row the server sent — a property delta, or a lifecycle move. It is what the rebase above is expressed in, and it is public because `LocalStoreWriting` is. The delta case carries `tier` but deliberately not `sourceId`, which the same `PATCH` accepts: no local write path sets that column, so rebasing it would make the field change on the arrival of an inbound frame about something else. Queued `bulk` writes are translated alongside the single-item kinds; `bulkAction` is not, because it selects rows by a filter expression rather than by id and answering it locally means evaluating the `GET /items?filter=` grammar, edge traversal included.

- **`StoreRecovery`**, the record of a store that had to be rebuilt: why, where the old one went, where the salvaged queue was written, and how many queued writes, dead letters and pending blob uploads came out of it, plus the event cursor it had reached. **`StoreRecovery.Cause`** distinguishes a store this build cannot read from one a newer build wrote.

- **`MarfaClient.storeRecovery`** carries the same value, non-`nil` only when the fail-safe ran. It is the answer for a pure-local client, which has no sync engine to subscribe to, and for any app that would rather ask than listen. It is `nil` on a client built from a caller-supplied container, because the SDK did not open that store.

- **`StoreRecovery.truncatedTables`** names the parts of the salvage that stopped early. A store is set aside for a shape this build has no model for, which says nothing about its bytes — but the same path takes a store that really is damaged, and there the read stops mid-table and looks exactly like the end of it. While that list is non-empty the counts beside it are floors rather than totals, and the sidecar carries the same field. Reporting the rows reached as though they were the queue is worse than reporting nothing: an app showing "3 unsent changes" over 300 has told a person their work is accounted for.

- **`MarfaModelContainer.open(path:cloudKitDatabase:)`** returns **`StoreOpenResult`** — the container plus that optional recovery. `MarfaModelContainer.make(path:cloudKitDatabase:)` is unchanged and still returns the container alone; it now discards the recovery rather than never having had one.

- **The store schema moves to V3, and both stages are lightweight.** A store written by any build from 7.0.0 onward migrates forward with every row intact, which the previous arrangement could not do for any change to an existing model's shape. Two additions: an item now keeps the `space_id` the wire has always sent, which the store dropped on the way in, so an item read back locally can say which space it came from; and a cached-types table ships empty, ahead of the local type registry that needs it, because adding a table inside a migration that is happening anyway costs nothing and adding one on its own costs every device a migration.

  **A store older than 7.0.0 is a quarantine and an empty rebuild, not a migration**, and that is worth stating plainly because the version numbers suggest otherwise. 7.0.0 dropped a column from the item model in place without moving the schema version identifier, so a store written by 6.x or earlier holds an item shape that neither `MarfaSchemaV1` nor `MarfaSchemaV2` describes as they are compiled today. It matches no version in the plan, so it takes the path above: moved aside intact, queue and cursor written out beside it, and the app opens on an empty store that re-hydrates from the server. Measured rather than reasoned about — the committed store fixture's recorded entity hashes match V2 exactly, and it migrates with every row intact. In practice a device that has run any build since 7.0.0 already met this as a silent delete-and-rebuild at the time and holds a store that migrates; a device coming from 6.x or earlier meets it here, and is told about it rather than quietly losing the queue. The V1 stage is kept for lineage and describes no store that shipped.

  Extensions were *not* moved onto the item, and that is a decision rather than an omission. They already round-trip through the metadata row, which is the layer the server writes them through; a column on the item would put one field in two places and leave the two able to disagree. A test pins the layering so the column is not added later.

## [16.0.0] — 2026-09-02

Major, and the breaking changes are the smaller half. **A synced client did not
sync.** Several independent defects, each sufficient on its own: it never
applied `metadata.changed` or `edge.updated`; it wrote a second copy of every
edge it created, and of every bulk item it created without naming an id itself,
which is the ordinary case rather than the corner because the store mints an id
for exactly those; its event stream was torn down every two minutes and
replayed from the cursor; and a store that had never imported stayed empty,
because the only thing that would fill it was a separate call the documented
setup never made. An app built by following the README opened on a blank first
screen against a server full of content, and the stream above it looked healthy
throughout.

Fixing that is what moves the surface. `LocalStoreWriting` drops `setMetadata`
for `upsertMetadata` and **stops every conformer compiling**: an event and an
import both carry the server's whole metadata row, so the engine no longer
performs a tags-only write at all. Inbound metadata now replaces rather than
merges, extensions included, which means a namespace the server has dropped
goes away on the device too. `SyncEvent` gains two cases, `edgeUpdated(id:)`
and `mutationBlocked(kind:itemId:reason:)`, while `PendingMutationStatus` and
`PendingMutationState` gain one each, so an exhaustive switch over any of them
needs a new branch.

Two further breaks are unrelated to sync and share one cause: the vendored spec
these shapes are generated from had stopped tracking the platform.
`connections.install` loses `label:` and `ConnectionInstallResult` loses
`credentialId`, because the route dropped both while the SDK went on sending
the one and requiring the other — so every install failed to decode a call the
server had already carried out. `Integration.installedCount` arrives with the
same refresh, non-optional and with no default, so an `Integration(...)` built
in a fixture or a preview has to pass one.

**The changes the compiler will not find for you are the ones to read.** A 400
and a 409 now carry the code the server sent, rather than being flattened to
`validation_error` and `server_error`, so a consumer branching on
`MarfaError.code` will meet codes it has never seen before.
`DroppedMutationRecord.id` is no longer always the dead record's UUIDv4, and a
bulk row no longer always carries a `nil` `localId`. `SyncEvent.synced(at:)` is
no longer emitted for a store that has never completed an import, because an
empty queue on an empty store is a device that has not started rather than one
in sync. And a queued write that cannot succeed until the app does something is
now blocked rather than replayed forever — worth reading in full if you write
offline, because a queue whose remaining rows are all blocked also holds off
the first import.

`admin.platformTypes` is a new sub-namespace over two new public types,
`AdminPlatformTypesNamespace` and `DriftedPlatformType`. A platform-type row is
what makes items of that type resolve, so a build that stops shipping a type
leaves its rows behind; `drift()` lists them with a live item count and what
inherits from each, and `remove(_:)` deletes one where the server agrees
nothing still depends on it. Platform-admin only.

### Added

- **`SyncEvent` gains `edgeUpdated(id:)`, and an exhaustive switch over it stops compiling.** A closed enum gaining a case breaks every switch that enumerates it, which is why this is reported as the enum rather than as the case. Add the branch and the switch compiles again; there is no behavior to migrate. The event fires when an edge edited on another device reaches this one, which until now nothing announced because nothing applied it.
- **A queued write that cannot succeed until the app does something is now blocked rather than retried forever.** Three failures mean a mutation will fail identically on every cycle until something app-side changes, and the SDK had no way to say so: a replay that found no registered conflict resolver, a `409` on an update that outlived the conflict loop (a `.manual` strategy, a `.callback` resolver that kept declining, or a `source_id` the server holds against another row), and a non-network refusal that has simply failed too many times. Each was treated as a network blip, replayed on every cycle, and — because it set the cycle's error — made sync report failure permanently, so an app showed an error indicator that never cleared beside a queue that was never going to drain, and a genuine second failure was indistinguishable from it. Such a row is now skipped by the drain, does not fail the cycle, and surfaces as **`PendingMutationStatus.blocked(reason:attemptCount:lastError:)`** through `PendingMutationsQuery`, with **`SyncEvent.mutationBlocked(kind:itemId:reason:)`** emitted once as it stops. **`PendingMutationBlockReason`** is the new public enum naming the three (`resolverMissing`, `conflictUnresolved`, `retriesExhausted`), **`PendingMutationRecord.blockedReason`** carries it on the DTO, and **`PendingMutationState.blocked`** is the persisted state. **`SyncEngine.retry(id:)`** returns a blocked row to the queue and asks for a drain; a `resolverMissing` block needs no call at all, because the next drain that finds a registered resolver replays it.

  **`SyncEngine.init` and both `MarfaClient.synced(...)` factories take `maxReplayAttempts`**, defaulting to 5. It is the ceiling for that third case only, and it must be at least 1.

  **Network-class failures never count toward it and never block** — a connectivity failure, a `5xx`, a `429`, a `401` and a cancelled request are all statements about the environment rather than about the write, and they clear on their own. Blocking a valid write behind an outage, and then requiring a person to release it, would be worse than the defect this fixes. A blocked row holds back writes queued *after* it for the same item and nothing else, keeping the queue's per-item ordering without letting one stuck row stall unrelated work.

  **A drain request that arrives while a cycle is running is no longer dropped.** `SyncEngine.retry(id:)` promises a drain, and the moment an app is most likely to call it is while the engine is busy; before this the overlap guard discarded the request and the row waited for an unrelated wake-up, which against a live server — where the event stream stays open — may never come. A request arriving mid-cycle now runs one more cycle as soon as the current one ends. **This was already the behaviour an enqueue got, and it changes too:** a write enqueued while a drain is running now replays on the following cycle rather than waiting for the next network transition.

  **A queue whose only remaining rows are blocked also holds off the catch-up import**, so a store that has never imported stays empty until the block clears. That was already true of a row that retried forever; it is now a named consequence of leaving the import gates reading the whole queue, which they do because a blocked row is still an unsent write and the import replaces rows with no merge.

  **Breaking for exhaustive switches.** `PendingMutationStatus`, `PendingMutationState` and `SyncEvent` each gain a case, so a `switch` over any of them without a `default` stops compiling. That is the intended prompt: an app that renders `retrying` for a blocked mutation is telling someone to wait for something that will not happen on its own. **Downgrading is the direction that degrades quietly:** an older build has no `blocked` case, reads the row as `pending`, and replays it on every cycle again — and because the block reason is stored inside `lastError`, that build surfaces the raw prefixed string (`[blocked:resolverMissing] …`) as the error text it shows.


- **`admin.platformTypes` is a new sub-namespace, with `admin.platformTypes.drift` and `admin.platformTypes.remove`.** `AdminPlatformTypesNamespace` and `DriftedPlatformType` are both new public types. A platform type row is what makes items of that type resolve, so a build that stops shipping a type leaves its rows behind rather than dropping them — a rollback is the ordinary way it happens. `drift()` lists those rows with a live item count, the types inheriting from each, and whether it can be removed; `/health` publishes only the count, because it is unauthenticated. `remove(_:)` deletes one row and returns nothing, because the route's body is a constant and an echo of its argument. It is wrapped where account and space deletion deliberately are not: the server refuses it whenever items still carry the type, another type inherits from it, or the build still ships it, so unlike those two it cannot orphan readable data. Both are platform-admin only and throw `LocalModeUnsupportedError` on a pure-local client.

### Fixed

- **A healthy event stream is now held for the session instead of ending every two minutes.** The SSE request ran on the same `URLSession` as ordinary calls, and that session's resource timeout bounds a request's whole life rather than its idle time, so `GET /events` was torn down at two minutes however healthy it was. Every synced device then ran its stream-close path, reconnected, and had the server replay from `Last-Event-ID` — on a timer, forever, for nothing the server had said. The stream now runs on a session of its own that sets no resource timeout, leaving URLSession's own seven-day default in place, and is bounded by silence instead: every frame the server sends resets that bound, so it never ends a stream that is being fed, while one that has stopped delivering ends on `ClientConfiguration.streamTimeout` and reconnects exactly as it did before. A network change or the server closing the stream still end it as they always did. Opening the stream is bounded by the same value, so a subscribe against a server that accepts the connection and never answers now waits `streamTimeout` rather than the shorter `timeoutInterval`. **Ordinary requests are untouched** and still give up at `ClientConfiguration.resourceTimeout`.

- **A bulk replay reads the answer the server sent it, instead of discarding it.** All three bulk doors answer per entry, and the replay threw the whole response away — so a call whose entries the server refused was removed from the queue reporting success, with no dead-letter row, no `SyncEvent.mutationDropped`, and nothing an app could show for writes that had gone. A call where every entry errored reported exactly what one where none did reported. Each refused entry now lands in the dropped-mutation log under its own id, carrying the code the server gave it, and emits an event. That covers `items.bulk`, `edges.bulk` and `items.bulkAction` — the last keyed by the item id it failed on, because a filter-driven call has no page to index into. An id the server resolved to a different row — an upsert matching on `(source, source_id)` rather than the id the page carried — is logged rather than repaired: the answer carries ids and not rows, so there is nothing to adopt, and fetching one per entry would turn a page of thousands into thousands of round trips. The catch-up import reconciles it.

- **An atomic bulk page rolled back by the server is dead-lettered with the reason underneath, not the wrapper.** `atomic` defaults to true, so one refused entry rolls the page back and the server answers `400 bulk_atomic_rollback` with the real reason in `details.code`. Every such rollback is final, and always was — the route rolls a page back only on a validation-class refusal of one entry's content, and nothing worth retrying can reach it — but the dropped row recorded `bulk_atomic_rollback`, which says something was refused and never which thing. It now records the underlying code and the entry that caused it.

- **`ValidationError` gains `ValidationError.init(code:message:details:)`, and a 400 keeps the code the server sent.** `parseMarfaError` flattened every 400 to `validation_error`, discarding what the server actually said — the same loss a 409 had before the last release. `ValidationError.init(message:details:)` is unchanged and still stamps `validation_error`. Consumers branching on `MarfaError.code` for a 400 will now meet codes such as `bulk_atomic_rollback` where they previously saw only `validation_error`.

- **`DroppedMutationModel.payloadJson` has two shapes for a bulk kind, and the row id says which.** A row for a whole record holds the queue envelope, the entire page as enqueued; a row for one refused entry holds that entry alone, because a page can carry thousands and the refused one is the only part worth keeping. An id carrying a `#<key>` suffix is the second shape and a bare id is the first, so anything decoding that column for a bulk kind has to check which it has. Relatedly, `DroppedMutationRecord.id` is no longer always the dead record's UUIDv4, and a bulk row no longer always carries a `nil` `localId`.
- **A bulk item create on a synced client is one row on that client, under the id the server holds.** `items.bulk` wrote each entry to the local store under an id it minted, then queued the caller's input unchanged — so an entry the caller had not named itself reached the server anonymous, was minted a second id there, and the row that came back landed beside the one the device already had. Any synced `items.bulk` entry without a caller-supplied id ended up twice on the device that made it, with nothing to reconcile the two — and since the store mints an id for exactly those entries, that is the ordinary case rather than the corner. The queued page now carries the id each local row was written under, as `items.create` and (since the last release) `edges.bulk` already did. An entry whose local write failed travels as the caller wrote it, since there is no local row for a server-minted id to duplicate, and a network-only client is unchanged: it has written nothing locally, so it names nothing and the server mints.

- **A create that meets a conflict is refused once instead of retried forever, and one the server acknowledges is adopted.** A synced client names its own rows and sends that id with the create, so a lost response is retried under the same id. The server answers a repeat of an id the caller already holds with the stored row rather than a refusal — but the SDK threw that answer away, keeping whatever the device had minted, so an acknowledged repeat never picked up the version, the properties or the tags the server actually held. And a 409 that *did* arrive was classed transient, because `MarfaError.isPermanent` sees only the status and a 409 on an update is the ordinary version conflict. On a create there is nothing to resolve: the id belongs to a space this caller cannot see, or the row's type is not the one declared, and the identical request is answered identically forever. The mutation retried on every drain with no ceiling, and the queue's ordering stranded every later edit to that item behind it. A create replay now applies the item and metadata the server returned, and a 409 on `createItem` or `createEdge` is dead-lettered with the server's own code — `conflict`, `type_mismatch` — reaching apps through `SyncEvent.mutationDropped` and `DroppedMutationsQuery`. A refused `createItem` still cascades to its dependents and purges the local ghost. **An edge create that is dropped now loses its local row as well**, on any permanent refusal rather than only a conflict, and whether it was refused directly or dropped by the cascade behind a refused `createItem` — a cascaded edge row otherwise survived pointing at an item that had just been purged. **A 409 on an update is untouched** and still resolves through the conflict strategy.

- **A 409 carrying no version-conflict body keeps the code the server sent.** It was reported as `server_error`, so the one thing such a response says — whether the id is somebody else's or the type disagrees — was lost before any caller saw it. Other statuses are unchanged.

- **An edge edited on another device reaches this one.** The engine's event switch handled `edge.created` and `edge.deleted` and dropped `edge.updated` to its default branch, so a property carried on an edge, such as an ordering on a containment link or a label on a relation, was edited on one device and stayed at its old value on every other one, indefinitely. A full sync did not repair it either: the edge already existed locally, and the only two things that wrote one were the two events that were handled. The frame carries the whole edge, the same envelope `edge.created` uses, so applying it replaces the local row outright and stores an edge this device has never seen — the create can have landed before this device's cursor, which makes the edit the first mention of it.

- **An edge created on a synced client is one row on that client, under the id the server holds.** Both create doors had the same defect. The local store wrote the new edge under an id it minted and the replay then posted the create without it, so the server minted a second id of its own and the `edge.created` event that came back under that id inserted a row beside the one the device had already written. Every edge made while synced ended up twice on the device that made it, with nothing to reconcile the two — anything counting or ordering edges was wrong on that device from then on. `edges.create` now sends the id the store wrote the row under, as the item path already did, and applies the edge the server returns, so the row the device holds carries the server's space and timestamps. `edges.bulk` does the same per edge, and **`BulkEdgeInputItem.id` is no longer discarded on a synced client**: the caller's id now names the local row and travels on replay, where before it was dropped in favor of a mint the caller never saw. A network-only client is unchanged: it has written nothing locally, so it names no id and the server mints one.

- **A synced client fills itself and replays what it owes when it comes online, rather than when its event stream closes.** `SyncEngine.start()` began watching the network, opened `GET /events` and did nothing else, and two defects shared that one absence. A store that had never synced stayed empty, because the stream carries only what happens after it opens and `SyncEngine.performInitialSync` was a separate call the documented setup never made — so an app built by following the README opened on a blank first screen against a server full of content. And a write queued while the engine was stopped was never replayed, because the only two things that drained the queue were a ping from a fresh enqueue, which a listener that has not yet subscribed never receives, and the stream closing, which against a live server does not happen. Coming online now runs one catch-up step before the stream opens: drain the queue if anything is in it, then import if this store has never completed an import, then subscribe. **Consumers that call `SyncEngine.performInitialSync` themselves keep working and can drop the call where it was only standing in for this** — it still refuses over a queue that has not drained, still imports on demand, and a call that lands while the engine is catching up joins that run instead of paging the library a second time.

- **The engine reports itself online while its stream is open, not only once it has closed.** `ConnectionState` reached `.online` after the SSE stream ended, so for the life of an open stream — against a live server, the whole session — it read `.connecting`, and the proactive drain fires only on `.online`. A write made while the app was simply running therefore sat in the queue until something else happened to it. A drain request that arrives while the engine is still coming online is now honored once it is, rather than spent against a gate that refuses it.

- **An engine started on a `ConnectionStateManager` that is already online opens a stream.** `ConnectionStateManager.start()` is idempotent, so an app that started the manager itself left the engine with no transition to act on and no stream at all until the next network flap.

- **A synced client applies `metadata.changed` events, which it never has.** The engine decoded the event as `{ item_id, metadata }`; the server sends `{ type, item, metadata }`, the same envelope as every other item event. Every such frame failed to decode and was dropped, so nothing another device did to an item's tags or extensions reached a synced client until it re-imported. Nothing exercised the decode against a real frame, which is why the stream looked healthy the whole time.

- **The initial import carries extensions.** `performInitialSync` mapped each row to `MetadataInput(tags:)` and dropped the extensions the wire had already sent, so an app reading sidecar state the server held saw nothing and had no second pass that would ever fill it in.

- **`LocalStore.setMetadata` no longer clears an item's extensions.** It replaced the whole row with a tags-only one. It backs `client.metadata.set`, which replays `PUT /items/{id}/metadata` — a route that writes the tags column and touches nothing else — so the local write disagreed with the server the moment the replay landed, and disagreed silently. Its signature is unchanged; only what it does to extensions is.

- **A metadata or extension write against an item the local store does not hold now throws `NotFoundError` instead of orphaning a row.** `LocalStore.setMetadata`, `mergeMetadata`, `setExtension`, `deleteExtension` and `removeTag` all refuse, mirroring the 404 their routes answer with. `removeTag` is the one that reads as harmless and is not: it fetched an empty row, filtered nothing out of it, and wrote it back, inserting a detached row on behalf of a call whose whole purpose was to take something away. Writing anyway did not merely differ from the server: a metadata row attaches to its item as it is inserted and `upsertItem` never adopts one already sitting there, so the row stayed invisible to every read that reaches metadata through the item, and the item arriving later did not repair it. `addTags` refuses too, through `mergeMetadata`.

- **`connections.install` can succeed against a current server, which it could not before.** The route dropped `label` from its request and `credential_id` from its response, and the SDK went on sending the one and requiring the other — so every install failed to decode a call the server had already carried out, leaving a live connection the caller was told nothing about. The vendored spec these shapes are generated from had stopped tracking the platform, so nothing in the repository disagreed with itself and no test could see it. `ConnectionInstallInput.label` and `ConnectionInstallResult.credentialId` are gone because the route no longer has them. A credential id is still reachable: read the installed connection.

### Changed

- **`ClientConfiguration.streamTimeout` is new**, and both `ClientConfiguration` initializers take it. It is the event stream's inactivity bound: how long the stream may go silent before the client treats it as dead. The default is 60 seconds, twice the server's thirty-second heartbeat, so a stream is only given up on once a whole ping interval has passed unheard — the same bound the realtime guide already publishes for any SSE client. Raise it for a deployment whose proxy batches SSE frames. It is defaulted on both initializers, so no existing call site changes. **`ClientConfiguration.resourceTimeout` keeps its meaning for ordinary requests** and no longer governs the stream.

- **What an app watches while the first import runs is `SyncEngine.fullSyncState` and `FullSyncStateQuery`.** No sync event was added for it. A store that has never imported reads `notYetSynced` until the import lands — `syncing` while queued writes are replaying — and `synced(at:)` once it does. An import that fails reads `failed(at:error:)`, the stream opens regardless so the device is not also deaf to what happens next, and the next online cycle tries again. The engine takes that retry decision from `SyncEngine.lastFullSyncAt`, which a completed import stamps and nothing else does, rather than from the state it renders.

- **A store that has never completed an import can no longer report `synced(at:)`, and `SyncEvent.synced(at:)` is not emitted for one.** An empty mutation queue on a store with nothing in it is a device that has not started, not a device in sync. Before this, a write queued before the first start reported itself caught up from the drain that runs in front of the import, so an app was told it was up to date while showing an empty library. The first `synced(at:)` a fresh store reports is now the one its import lands. A store that has already imported is unaffected.

- **A failed retention-gap resync now reports `failed(at:error:)` as well as logging.** When the server has discarded the events a device's cursor points at, the resync that follows goes through the same catch-up as every other, so a failure reaches `SyncEngine.fullSyncState` instead of only the log. The two `sync.catchup_too_old` log lines are unchanged.

- **`LocalStoreWriting` drops `LocalStoreWriting.setMetadata` and gains `LocalStoreWriting.upsertMetadata`.** **This breaks every conformer**: a protocol that gains a requirement stops compiling for anyone who implements it, and one that loses a requirement takes the witness with it. The protocol is the seam the sync engine writes through, and the engine no longer performs a tags-only metadata write at all — an event and an import both carry the server's whole row. A conformer replaces `func setMetadata(itemId:input:) async throws -> Metadata` with `func upsertMetadata(_ metadata: Metadata) async throws`.

- **`LocalStore.upsertMetadata` is new**, alongside `upsertItem` and `upsertEdge`: it stores a metadata row the server sent, replacing the local one wholesale. Tags and extensions are two halves of one row on the wire, so writing them as a unit is what lets a namespace the server has dropped go away on the device too. `LocalStore.setMetadata` remains for the tag-replace a consumer asks for.

- **Inbound metadata replaces rather than merges, extensions included.** A `metadata.changed` event and the initial import both make the local row the server's row, so a namespace absent from what the server sent is removed locally, and a namespace the server holds replaces the local one whole rather than merging key by key. An extension written while offline is not lost to this: it replays, the server emits the change, and the row that comes back carries it.

- **A `metadata.changed` frame stores the item it carries, on every such frame rather than only for an unknown item.** A metadata row attaches to its item as it is written, and a tag added elsewhere can be the first this device hears of an item created before its cursor. Applying the item unconditionally carries the same exposure `item.updated` already has — a frame landing over an edit this device has queued replaces the local row with the server's — and it converges the same way, when the queued edit replays.

- **The event's `metadata` is optional.** The server spreads that key into the envelope only when the event carries a row, so a frame without one now stores the item alone rather than failing to decode and being dropped in silence.

- **`connections.install` is spelled `install(integrationId:credentialRef:configuration:)`, and `label:` is gone rather than deprecated.** Every caller passing a label stops compiling, which is the intended outcome: the route ignores an unknown key rather than refusing it, so a `label` kept for source compatibility would have gone on being accepted and gone on doing nothing. `credentialRef` binds the connection to an existing `system.credential` instead of provisioning one, which is how two integrations against the same upstream share an OAuth client configuration. `configuration` seeds the connection's configuration bag in the same round trip; the server validates its keys against the integration's manifest and refuses an undeclared one, so it is narrower than its type suggests. `ConnectionInstallResult` no longer carries `credentialId`, so anything reading it stops compiling too.

- **`Item` gains `orphaned`, and `Integration` gains `displayName` and a required `installedCount`.** These arrive with the spec refresh that fixed the install route above. `Item.orphaned` and `Integration.displayName` are optional and additive. `Integration.installedCount` is not: it is non-optional with no default, so every `Integration(...)` a consumer constructs — in a fixture or a preview, since the wire supplies it otherwise — stops compiling until it passes one. It is spelled `Int` rather than `Double` because the platform declares it an integer.

- **`OccurrencesResponse` gains `scan`, `expansionIncomplete` and `seriesErrorsTruncated`, and `OccurrenceScan` is a new public type.** `GET /occurrences` bounds what it will expand, and until now a response said only what it had returned, never what it had cost or whether it had stopped early. `OccurrencesResponse.scan` reports the read against every ceiling that could truncate it, on success rather than only on refusal, so a calendar approaching one is visible before a request starts failing. `OccurrencesResponse.expansionIncomplete` says `data` may be missing occurrences because expansion ran out of budget — narrowing the window does not recover them, since the budget is spent walking rules from their own start. `OccurrencesResponse.seriesErrorsTruncated` says the `seriesErrors` list is capped and `OccurrenceScan.seriesErrors` carries the real total. `scan` is non-optional, matching the route, which declares it required.

## [15.0.0] — 2026-09-01

Major, and every breaking change in it is a name that meant the wrong thing.

Two of the three are ordinary renames. The third is the reason the release is
worth reading: **`issuer:` meant the server URL, and every consumer written
against it got that wrong.** Both shipping Swift apps passed a server URL to a
parameter called `issuer` and had sign-in dead for weeks; the SDK's own docstring
examples showed the same wrong value. A helper that derived the issuer correctly
shipped as the fix, and a helper is opt-in, so the next consumer that did not
call it would have failed identically. The derivation moves inside.

Storage keys do not move with it, which is the half worth checking if you have
your own consumer: credentials are still keyed on the derived issuer, so a
consumer that was deriving correctly keeps every stored credential across the
upgrade.

One fix rides along and had been failing silently since the derivation helper
shipped. The pre-11.4.0 credential migration refuses an ambiguous server, and
that question was being asked of the issuer, which has a path by construction on
every Marfa deployment — so the guard refused everything and nobody could see it.

### Changed

- **`MarfaAuth`, `DeviceFlow` and `Passkey` take a `serverURL:` and derive the OAuth issuer themselves.** `MarfaAuth.init(issuer:)`, `MarfaAuth.clearStoredCredentials(issuer:)`, `DeviceFlow.start(issuer:)` and `Passkey.enroll(issuer:)` are all now spelled `serverURL:`, and every caller stops compiling until it passes the value it would give `MarfaClient`. A Marfa deployment publishes `https://<host>/auth` as its issuer, so the server URL is not the issuer — and **both** shipping consumers of this SDK passed the server URL to a parameter called `issuer` and had sign-in dead for weeks. A parameter whose affordance has a hundred per cent failure rate is misnamed, and `OAuthDiscovery.issuer(forServer:)` shipped as the fix for it, but a helper is opt-in and the next consumer that does not call it fails identically. `MarfaSession.end(serverURL:)` already worked this way and its argument is the same one. **`Passkey.enroll` is the odd one and is worth reading twice if you call it:** its parameter always meant the server URL despite its name, so its *value* semantics are unchanged and only the label moved — while the other three take a genuinely different value than before. Leaving it behind would have shipped a release where one label meant opposite things on the same three entry points, with the type system unable to tell them apart.

- **`MarfaAuth.serverURL` is a new public property**, carrying the value the caller supplied. `MarfaAuth.issuer` remains and is now the derived identifier rather than whatever the caller spelled, so it is finally named for what it holds. Build a `MarfaClient` from `serverURL`; `issuer` addresses `/auth` and never was the API base.

- **Storage accounts are unchanged, and this is the part to check if you have your own consumer.** The issuer is still what keys a credential, and it is still the derived `https://<host>/auth`. The change only moves *where* the derivation happens. A consumer that was already deriving correctly — the shape both first-party apps use — keeps every stored credential across the upgrade. A consumer that was passing a bare server URL as `issuer:` was, by construction, unable to sign in at all, so it has no stored credential to lose. **One shape does move**, and it is the same one the guard below excludes: a deployment whose server URL itself ends in `/auth`. Its issuer was `<server>/auth/auth` under 14.x and is `<server>/auth` now, so a credential stored against it is orphaned and the person is signed out once. No first-party deployment has that shape.

- **A `serverURL:` that is already an issuer is absorbed rather than compounded.** One premise — a URL whose last path component is already `auth` is an issuer, not a server — held in one internal place and acted on by every entry point taking a `serverURL:`. The sign-in flows decline to append; `Passkey.enroll`, which builds an ordinary route rather than an issuer, strips instead. `MarfaSession.end(serverURL:)` joins them, which is a behavior change on an entry point that did not otherwise move. `OAuthDiscovery.issuer(forServer:)` itself stays unguarded, because those are two different questions: a caller who names the helper has stated what it is handing over, while a caller filling in a `serverURL:` parameter has stated nothing and is most likely to supply the value it was passing before. **The guard exists because not every double-derivation fails loudly.** A sign-in does — discovery refuses a document whose issuer is not the one asked for. A *clear* does not: `MarfaSession.end` and `clearStoredCredentials` would address accounts under `/auth/auth`, delete nothing, and report success, leaving a working credential on a device the person believes is signed out. The price is that a deployment genuinely rooted at a path ending in `/auth` cannot be reached through these entry points and must drive `OAuthDiscovery.endpoints(for:)` directly. `Passkey.enroll` is where that price is worth paying most: it is `async`, non-throwing, and cannot observe its own outcome by design, so before this it would have opened `/auth/auth/passkey/enroll`, taken a 404 inside the system browser, and reported nothing at all.

### Fixed

- **A pre-11.4.0 credential is migrated again.** `restore()` promotes the old host-only keychain account to the versioned spelling only when the server is unambiguous — HTTPS, no explicit port, no path — because the old account is keyed on the host alone and another authorization server on that host could have written it. That question was being asked of the *issuer*, and every Marfa issuer has a path by construction, so once consumers began deriving the issuer correctly the check refused on every deployment that exists and the migration silently stopped running. It now asks the server URL and keys from the issuer, which is what it always meant. **The failure was invisible from outside:** nothing threw, `restore()` simply found no account and returned `nil`, and an app cannot tell that apart from a user who never signed in — so a signed-in person was asked to sign in again with no error anywhere. No test caught it because every test of the migration builds its own path-free issuer and passes it directly, exercising a shape the shipping consumers can no longer produce.

- **`KeyRole.admin` is renamed to `KeyRole.instanceAdmin`, and its wire value is now `instance_admin`.** Source-breaking for any caller naming the case, and the case is the smaller half: `ApiKey.role` and `CreatedKey.role` are non-optional, so a `Codable` enum meeting a raw value it has no case for throws `DecodingError.dataCorrupted` and **fails the whole decode**. Against a current server this SDK therefore could not read `keys.list()` or `keys.create()` at all until this change. The old wire value is deliberately absent rather than kept as a second case: carrying it would keep a retired word decoding indefinitely and hide a server nobody upgraded.

- **`Transport.uploadMultipart(...)` requires an explicit `method:`**, having defaulted it to `.post`. **A caller that omitted the argument stops compiling**, which is the intended outcome and the only reason the default was worth removing: a defaulted verb is invisible in the source, so a call site that omits it reads as a route with no method at all, and neither a person nor a scan of the sources can tell which verb it sends. No call site in this package ever omitted it, and the one caller — `ProfileNamespace.uploadAvatar(...)` — already spelled it, so nothing here changed behavior. Add `method: .post` to any call site that relied on the default; the request it builds is identical.

## [14.2.0] — 2026-08-27

Minor. Three of the four changes here are about one seam: a local store, a
credential, and the fact that nothing connected them. The SDK had no notion of
which account populated a store, so every consumer holding both invented that
guard itself, and the one that shipped keyed it on the credential rather than on
the account — which moved one account's whole library into another's space. The
initial sync also imported items without their edges, leaving a signed-in device
showing a library with no relationships, and imported over local writes that had
not yet replayed.

**One entry below is not from this wave and is source-breaking.**
`CreateItemEdge`'s removal landed on `main` before any of this and reached no
changelog, so it is recorded here rather than published unrecorded. This release
is numbered a minor with that in it deliberately: the project is pre-release, and
both shipping consumers were checked against the removal and compile unchanged.
A third consumer needs the migration note under **Removed**.

### Added

- **The SDK knows which account a local store belongs to.** It had no such concept: `MarfaClient.synced(...)` opened whatever store was at `storePath` and built an engine against it, and the sync state that would betray a mismatch — the SSE cursor, the full-sync stamp — is keyed to the file rather than to an account. So handing a different account's credential to an engine pointed at the same store resumed from the previous account's cursor and replayed the previous account's queued writes into the new space, and nothing noticed. Every consumer with a store and a switchable credential had to invent the guard, and the one that shipped compared API-key hashes — which are only ever written when a key is saved, so an install that reached its first account by OAuth had nothing recorded to compare against, the guard stayed silent, and that account's entire library uploaded into the second account's space. The credential is the wrong identity for the question. `MarfaAccountIdentity` pairs the space id with the server it was read from: per-account, assigned at provisioning, identical for an API key and an OAuth token, and unchanged by a rotation — none of which is true of a token or a key. `MarfaClient.accountIdentity()` resolves it, `storeOwnership(for:)` and `storeOwnership(resolvedWith:)` compare it against a claim recorded in the store's own `sync_state` table, and `claimStore(for:)` records one. **Asking never records**, which is load-bearing rather than fastidious: at the moment a caller asks, the upload it is deciding whether to run has not happened, and a resolve that quietly claimed would make the retry after a failed upload read as `sameAccount` and skip the check protecting it. `StoreOwnership` has four cases and not two, because `unresolved` must not collapse into `sameAccount`: a caller deciding whether to *discard* a store has to read a failure to resolve as "do nothing", since wiping on a network blip destroys data the next sync would have reconciled, while a caller deciding whether to *upload* has to read it as "stop", since writing into the wrong space cannot be undone and another person can read it. One boolean cannot carry both, and a consumer modelling it as "did the account change" gets one of them backwards.

- **`auth.me()` wraps `GET /auth/me`.** The route has been there and this SDK did not expose it, so a consumer needing the space behind its credential hand-rolled a `URLSession` call — one did. `space` is always present and `space.id` is non-optional, which is what makes it usable as an identity where `Profile.accountHolderItemId` is not: that field is optional, so every consumer reading identity from it needs a `guard let` and an answer for the nil case, and the safe-looking answer there is "unchanged". `user` is `nil` for a credential with no person behind it, the ordinary case for an API key.

- **`MarfaSession.end(serverURL:clientId:storage:revoking:)` ends a session in one call.** Doing it properly took two calls in the right order plus a value nobody could guess, and each step failed silently when missed. `MarfaAuth.signOut(_:)` revokes and clears the *tokens* account, leaving the pending PKCE account and both pre-11.4.0 spellings behind, and it is a no-op for any provider that is not a `StoredTokenProvider`; `MarfaAuth.clearStoredCredentials(issuer:clientId:storage:)` reaches all four accounts and revokes nothing. Call one and not the other and you leave either a credential on the device or a live grant on the server, with nothing saying so at the time. **It takes the server URL, not the issuer**, which is the substantive difference: storage accounts are keyed on the derived `https://<host>/auth`, every consumer of this SDK reached for the bare host instead, and on a *clear* that mistake is quieter than on a sign-in — it does not throw, it deletes the two legacy accounts (whose keys are host-only, so the wrong issuer does address them), misses both current ones, and hands back success while the only credential that still works stays on the device. Deriving inside the call makes that unrepresentable. It returns whether the server was actually told, because giving up local credentials must not depend on reaching the network but an unrevoked refresh token outlives the app that stopped holding it and there is no admin route to clean one up. Deliberately outside the `AuthenticationServices` guard `MarfaAuth` carries: `MarfaAuth` does not exist on watchOS or tvOS and `DeviceFlow`, which exists precisely for those, writes the same accounts. The registered OAuth client id is untouched — the SDK never stores one, and discarding it makes the next sign-in register a fresh Dynamic Client Registration client with no admin route to remove it.

- **`InitialSyncError`**, thrown by `performInitialSync` when the mutation queue is not empty. Carries the count rather than a bare refusal: a number that does not fall across retries is a stuck queue rather than a busy one, and those want different answers from a person. `LocalizedError` from the start, so a SwiftUI error row shows the sentence rather than the case index.

- **The public names this release adds, listed.** Recorded after the fact, by the surface check introduced in a later version and run backwards over this cut. Adding a public name is not a source-compatible act in the way the rest of this section's analysis assumed: a consumer that already invented the same name for the same concept stops compiling on the bare spelling, which is what `MarfaAccountIdentity` did to one of them. Beyond the names spelled out above, this release adds the types `AuthMe`, `AuthMeSpace`, `AuthMeUser`, `NoLocalStoreError`, `OccurrenceSeriesError` and `OccurrenceWindow`; the method `MarfaClient.releaseStoreClaim()`; and the properties `CreateKeyInput.edgePermissions`, `CreateKeyInput.metadataPermissions`, `Occurrence.seriesId` and `OccurrencesResponse.seriesErrors`. If you hold a type of one of those names, expect to disambiguate.

### Changed

- **`PreviewEventDispatchReason` carries all eight of the route's cases**, having carried five. It is a raw-value enum with no unknown case, so a response naming one of the missing three threw a decoding error rather than degrading — the failure was real rather than cosmetic. **An exhaustive `switch` over it without a `default` stops compiling**, which is the only way a closed enum can gain a case.

- **`CreateKeyInput` can send edge and metadata permissions.** Both parameters are defaulted, so existing call sites compile unchanged. Without them a key minted through this SDK always took the server's default for both, whatever the caller intended; the two enums were already in the file, unused.

### Removed

- **`CreateItemEdge`, and `CreateItemInput.edges` changes shape with it.** The field was an array of objects carrying an edge type, a direction and per-edge properties; the route declares an object mapping edge type to target ids, outbound only. Anything populating it sent a body the schema refuses, and `BulkItemInput` in this same SDK already carried the correct shape — so two inputs disagreed about one field. `CreateItemEdge` is removed rather than deprecated because it could only ever build a refused request, and leaving it in place would leave a trap. **A call site passing `edges:` to `CreateItemInput` stops compiling**, which is the intended outcome: it was not working, it was failing at the server. Replace `[CreateItemEdge(edgeType: "core.about", ...)]` with `["core.about": [targetId]]`. Inbound edges and per-edge properties are not expressible here and want `client.edges.create(...)`.

### Fixed

- **The initial sync no longer overwrites a local edit that has not replayed.** It called `upsertItem` on every row it received, and `upsertItem` replaces all of an item's columns with no version check, while `setMetadata`'s contract is replace rather than merge. The conflict machinery could not help: it runs only on an outbound update meeting a 409, and is unreachable from the import. So an edit made offline and still queued lost to the server's older body, silently, and the queued mutation then replayed on top of a row whose earlier state nobody could see. It now refuses, and the refusal belongs here rather than in the caller for a specific reason: a consumer cannot ask this question at the moment it needs to. `hasPendingMutations` hangs off `SyncEngine`, and the caller deciding whether to import is typically holding a local client, which has neither an engine nor a queue — so what it actually writes is `syncEngine?.hasPendingMutations ?? false`, which answers "safe" because there was nothing to ask. A presence check standing in for a liveness check, and one that reads as correct. Per-row skipping was the alternative and cannot be made complete: a queued mutation carries an optional `localId` and the three bulk enqueues set none, so a bulk write is invisible to any "does this item have a pending edit" test. **This is a behaviour change rather than a source-breaking one**: a caller that previously imported over a non-empty queue now gets a thrown error where it used to get silent data loss. The one caller inside this package, the `catchup_too_old` branch, drains before importing rather than refusing — it is running, which is what a drain requires, and it is the only thing that ever asks for a full import, so a refusal there would leave the store stale with no route back.

- **The initial sync imports edges, so a device that signs in gets relationships and not just items.** `performInitialSync` paginated `/items` and stopped there, and its own docstring recorded that as a deliberate limit — edges "arrive via SSE once emitted", with a per-item edge fetch suggested for anything that needed them sooner. That holds for one screen and does not hold for a library: edge reads resolve against the local store whenever one exists, so a store with no edge rows shows every item with none of its connections. Related is empty, a thread shows a root with no replies, attachments show none. It does not heal either, because SSE delivers only events after the cursor and a fresh install has none, so edges created before the device signed in are never emitted to it and the gap is permanent rather than eventual. A consumer could not close it from outside: `MarfaClient.localStore` is `private`, so `LocalStore.upsertEdge` is public and unreachable, and `edges.create` on a synced client would enqueue a mutation to re-create edges that already exist server-side. The import now walks `GET /edges` the same way it walks `/items`. Two things this also repairs, both wider than first sign-in: the `catchup_too_old` branch clears the cursor and calls this function, so a client whose cursor fell outside the retention window was losing every edge emitted during the gap; and the local-to-server migration path a consumer app offers as ordinary sync setup was wiping its store and repopulating it from this import, which returned items and no edges. The pass order does not matter and is not an accident — an edge holds its endpoints as plain id columns with no relationship, precisely so one whose item has not arrived is stored rather than refused. `limit` is clamped to 500 for the edge pass because that is the route's ceiling and a larger value is refused rather than clamped. The return value still counts items only: widening it would break every existing call site to report a number no caller currently asks for, so the edge count is logged instead.

- **`UpdateItemBody` emitted `snapshot` where the route reads `force_snapshot`.** Nothing set it, so nothing broke — it was waiting for the first caller to wire a force-a-snapshot option through and find it did nothing. The type is internal, so the rename costs no caller anything.

- **`Occurrence` and `OccurrencesResponse` were missing four fields between them**, including the window the server actually expanded — which can be narrower than the one asked for, with nothing else saying so.

## [14.1.0] — 2026-08-26

Minor: two additions and no source-breaking change. Both exist because a
consumer app got something wrong that this SDK made easy to get wrong — one an
auth parameter that does not mean what it is called, the other a question with
no cheap answer, which an app answered by decoding its whole library on every
save.

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
