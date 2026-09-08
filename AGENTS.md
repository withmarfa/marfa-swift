# MarfaSDK

Swift SDK for the Marfa API, equivalent to the TypeScript `@withmarfa/sdk`. SPM package, zero external dependencies, Apple platforms only, Swift 6 language mode with complete strict concurrency.

**Query the docs MCP before re-deriving a documented surface** from source. Docs live only in `withmarfa/docs`; a change touching a public surface opens a companion pull request there.

## Shape

- **Two products.** `MarfaSDK`, and `MarfaSDKTestSupport` for public test scaffolding. Test support carries no semver stability across SDK minor versions.
- **`Transport` is a protocol**, with a URLSession implementation in production and a mock in test support. Everything HTTP routes through it, which is what the coverage check below can see.
- **Namespaced API**, `client.items.create()` and so on. Dates cross the wire as ISO 8601 strings rather than `Date`, so apps parse as they need.
- **Errors are an open base class with final subclasses**, so callers pattern-match on the subclass rather than on a code.
- **Both client factories are `async throws`**, because `@ModelActor` construction must run off the main actor. A synced client's caller then starts the sync engine.

## The local store

SwiftData under `@ModelActor`, CloudKit-compatible from day one: no uniqueness constraints, all properties defaulted, all relationships optional with an explicit inverse, no deny rules, Codable enums by raw value.

- **Old schema versions own frozen copies of the model classes; the live classes are always the current version.** The reverse arrangement would repoint the store, the queue, every query and every test on each schema change. This one works because nesting is invisible to Core Data: an entity is identified by its name and hashed from that name and its property descriptions, not from where the Swift type lives.
- **Never edit a frozen namespace.** That changes what its version hashes to, no version then matches a real store of that age, the stage never applies, and the device takes the fail-safe path — silently, and never on a fresh install, which is every machine that would have caught it.
- **Never instantiate a frozen model class in a test.** Two model classes sharing an entity name is what makes a versioned schema work, but SwiftData keys part of its runtime state by that name, so creating an *object* of the frozen class in a process that also creates objects of the live one leaves the two able to be confused. It surfaces as an unknown-key exception naming the newest version's column, thrown from an insert that never mentions it, in whichever test runs next: it needs the whole suite's ordering to appear and is invisible when the file runs alone. Entity *descriptions* are fine. Seed an old store from the committed fixture instead, and read it back with raw SQLite rather than fetching.
- **A store this build cannot open is quarantined, never deleted.** A rename cannot fail for the reason the open failed, so it is the only step allowed to decide whether the app starts over, and **the rebuild is conditional on it**: no quarantine means an error, not a fresh store. A sibling that will not move is judged by what it is, and **the support directory never is** — it holds the only copy of the externally-stored blob bytes and is inert to the store that replaces it, so deleting it would reach the end state this whole path exists to prevent. Salvage then reads the quarantined file with **raw SQLite**, because the refusal is a model-hash check and SwiftData is the one component guaranteed unable to read it. A read that stops mid-table is named as truncated rather than reported as a total, because stepping to the end of a table and hitting a bad page look identical.
- **Predicate safety is pinned by a test**, because a predicate that compiles can still crash at runtime. Predicate against the raw columns rather than Codable enum cases, use captured-value short-circuits rather than composing predicates at runtime, and compare against the empty string rather than using emptiness helpers.
- **The store's schema version only reaches disk from V3 onward.** The container was handed a schema built from a model array rather than from a versioned schema, so the identifier was never written and every older store on disk records the first version whatever it actually holds. The first version comparison that can tell the truth is the bump after V3.

### Applying the server's changes

- **An inbound item frame is rebased, not copied over, and a frame behind the row is refused.** The read, the rebase and the write happen in one hop, so no other write to that row lands between them. **That guarantee stops at the row**: the queued edits are gathered beforehand, so an edit enqueued in the gap is not rebased and the field shows the server's value until the queue drains and the server echoes it back. The write is not lost, and closing the window needs the store and the queue under one lock, which they do not share. The version check is skipped while a row has queued writes, deliberately: a local edit bumps the stored version, so on such a row the column is an optimistic guess rather than a server fact and cannot order anything.
- **An item frame never writes the metadata layer.** The server owns that layer and announces it separately.
- **A removal reaches a device two ways and the engine has to apply both.** A purge says a row is gone for good, which is not what a trash says. The other way is silence: a row purged while the device was away is *absent* from the re-import rather than changed in it, so no event describes it and only the prune can notice.
- **The prune's premise is that the keep-set is the entire server side, so every way of getting a short answer is a way of deleting rows.** Three are closed and each was a different set of rows destroyed. The import asks for every state, because the listing excludes trashed rows by default and reading that as the whole library empties the device's bin. It asks for metadata and system rows, because the route excludes those the same way while the stream that fills this store filters on nothing, so the keep-set would omit every device, connection and activity row. And a row the queue holds a create for is protected, asked once before the first page, because a write made during the paging that follows is queued *and* absent from the answer, which is exactly the shape a prune mistakes for a purge. A fourth way is a short *read* rather than a narrowed request, and a page claiming more results while carrying no cursor now throws rather than ending the loop silently. **The wire assertions in the removal tests are the only place a narrowed request can be caught**, because a mock answers whatever is queued regardless of the query. **Edges are not pruned**, which is the same defect one layer down and is not closed.
- **An unrecognised event type is logged, not dropped.** A silent default arm made an unhandled type indistinguishable from one deliberately ignored, which is what let a purge announcement sit unapplied after the server began sending it.

### Local reads and search

Local search narrows on the indexed columns in a predicate and then scans the survivors in Swift, because the properties blob is invisible to the predicate engine and SwiftData has no full-text index. It takes the same filters as the remote call and mirrors the server's exclusions, and **its divergences are listed in the method's own doc comment**: matched fields, tags, subtype inheritance, limit handling, ranking and snippets all differ.

**One interface, local baseline.** Search resolves through the store whenever the client has one, synced or not; asking the server's index is a separate, explicit call for the cases the divergences rule out. Sync used to switch this over, so the same call meant a local scan or a network round trip depending on a setting made once and forgotten.

## The reactive layer

Every query object is `@Observable` and `@MainActor`, so it passes straight to a SwiftUI view. They are vended by a store the client makes, which is `nil` for a network-only client, and they subscribe to context saves, debounce, and refetch on the main actor.

**Search is the one query that does not work on the main actor**, delegating the whole scan to the store actor and publishing results back, because it decodes each candidate's properties JSON. Its term is fixed per query, so search-as-you-type builds a new query per term and stops the old one.

## Auth

- **The flows take a server URL and derive the issuer themselves.** They used to take an issuer the caller derived and every consumer got it wrong, because a deployment publishes its issuer under a path while the server URL is the value everything else in this SDK wants. Passkey enrolment shares the label but derives no issuer: it builds an ordinary route, so it strips the path a caller supplied rather than appending one.
- **The web session is ephemeral**, so each sign-in starts with a fresh cookie jar and signing out actually ends the identity provider's session.
- **Native passkey sign-in is deliberately not implemented.** Those endpoints are session-cookie-gated rather than bearer-gated, so a native client cannot reach them. Once enrolled, the web sign-in page surfaces the passkey option.
- **The transport refreshes on 401, and naming the token is what bounds recovery.** A 401 reports the refused credential back to the provider, which exchanges it only while it is still the credential in hand, so requests already in flight when a rotation lands do not each start their own refresh. A rejected grant latches, so later calls fail with no network at all.
- **Keychain access goes through a protocol**, with an in-memory substitute in tests because SPM test binaries run unsigned.

## Route coverage

A test compares the routes the SDK calls against the operations the vendored spec declares, **in both directions**. Nothing else does, and before it the two surfaces drifted apart silently.

**What it guarantees:** every call written through the transport in the library sources is either read into a method and path, or reported by file and line with the reason it could not be. A composed path is refused rather than half-read, because a concatenated path would otherwise read as a route the spec declares and neither direction would fire.

**Prose never counts as a call, in either direction**, and this is the part that was wrong three times, so it is stated as the property rather than as the mechanism. Prose means anything the source contains that is not code the compiler runs, and **the definition is deliberately larger than the list of constructs modelled**, because narrowing it to what has been implemented is exactly what produced the last three defects. A construct that is prose and is not modelled is a gap in the implementation, not a case outside the rule. Over-blanking hides call sites; under-blanking *invents* them, and that is the silent direction, because an invented route subtracts a genuine gap from the report and takes the suite green.

**Attack the boundary, not only the internals.** Every defect found in this check was reached by testing whether the stated scope of its guarantee was true, not by finding a bug in the code. **A guarantee's stated scope is a claim like any other, and a claim that is only written down is a claim nothing checks.** When you state what a check delivers here, state what it cannot see in the same breath, say which of those you constructed an input for, and pin the ones you are leaving open with a test named for the limitation.

**What it does not cover:** HTTP that never goes through the transport. The OAuth code builds requests directly and most of those endpoints are read from the discovery document at runtime, so there is no literal to compare and no operation to compare it to.

Two maps, and the distinction is the point. **Deliberately unwrapped** means the spec declares it and the SDK does not call it, on purpose, with a reason per entry; entries reading "no decision on record" are the ones worth revisiting. **Undeclared upstream** means the SDK calls it and the spec does not describe it, which has two causes needing opposite responses: an operation on the server's internal list is dropped from the public reference on purpose and there is nothing to fix, while a plain handler the reflection cannot see could be documented through the server's own hatch. Establish which before recording it. The suite also fails on stale entries, so a map cannot outlive what it describes.

**It measures against the vendored snapshot**, so everything it reports is relative to what was last synced. A separate scheduled workflow asks from outside whether the snapshot still matches the monorepo, because a trailing snapshot once cost a release: every signal was green over a connection install the SDK could not perform against any current server.

## Build and test

```bash
swift build
swift test
```

Real-Keychain tests tolerate a missing entitlement on unsigned SPM binaries; a signed host app exercises the real path.

**One suite talks to a real server**, gated on a URL and key, and reported as skipped with every test named rather than silently absent when either is unset. It writes items and edges into whatever space the key reaches and deletes them again on every exit path, so it needs a space whose data is disposable. **Never run it, or conformance, against production.**

**The key needs the extension permissions the suite's fixtures write**, or setup is refused at the extension write, which reads as a failing reproduction and is nothing of the kind. The suite is serialized for a related reason: each test holds an event stream for its duration, and in parallel they compete for the space's viewer cap, where a refused stream is indistinguishable from a device that never got an event.

## CI

- **`validate` is the gate**: build plus the full suite, on every pull request and every merge. A pull request is the only place that check can still stop something.
- **`validate` runs on docs-only pull requests too**, deliberately. The branch ruleset requires it, and a required check that never reports because a path filter excluded it blocks the merge with no way for an agent to clear it. That costs one build on a macOS runner, accepted as the price of merging without a person clicking.
- **`freshness` regenerates the codegen and diffs it, on main and dispatch only.** It guards drift in the vendored snapshots, which a source-only pull request cannot introduce.
- **Spec drift and consumer pins are scheduled and watch inputs rather than gating changes.** Drift is not folded into `freshness`, because re-syncing there would redden pull requests that have nothing to do with the spec whenever the platform is ahead of an unrefreshed snapshot. Unset credentials fail rather than pass: a guard that cannot run must not report green.
- **Neither job restores a remote build cache.** Swift precompiled modules embed absolute module-cache paths, so restoring artifacts after a workspace moves produces an immediate path mismatch. With no external dependencies a cold build is short enough that a cache adds failure state without earning its place.
- **Tests were main-only once and a release tag was cut from a commit whose tests had never run.** Nothing between "compiles" and "tagged" executed the suite, and the missing fix shipped in a version number. Test cost on a pull request is small and predictable; the alternative is learning the same thing from a release artifact.
- **Runner routing reads an Actions variable defaulting to hosted macOS.** Revert it to a hardcoded hosted label before this repository goes public: a self-hosted pool must never run an untrusted pull request.

## The public surface

A committed file records every public and open declaration **as of the last release**. `validate` regenerates it at HEAD, compares, and fails when the unreleased section of the changelog does not name a declaration that was added, removed or retyped.

- **Regenerate the baseline at a release cut and never in between**, after the unreleased section has been renamed, so both moves land in one commit. Forgetting is loud rather than silent: the next change reports the last release's entries as unaccounted for.
- **Additions are held to the same standard as removals**, which reads as excessive and is not. A release analysed as purely additive broke a consumer on first compile, because the SDK added a public name the consumer had already invented for the same concept. A changelog listing the names a version adds lets them see it before they bump.
- **Members roll up**: a type that arrives or leaves is reported once rather than per member, and an enum's cases report as the enum, because a closed enum gaining a case breaks an exhaustive switch.
- **What it cannot see is protocol conformances.** Dropping a public conformance is source-breaking and lives in the symbol graph's relationships under a pile of synthesised entries; separating declared from synthesised is its own piece of work, and this check is silent on that class.

## Codegen

Three generators, all SwiftPM-driven, with committed output.

- **Generated files carry a do-not-edit header**, and a hand-edit is overwritten on the next regen.
- **Freshness is gated in CI** by running the generator and diffing. A failure always resolves the same way: regenerate locally and commit the delta.
- **The spec snapshot is vendored** to keep CI self-contained, and refreshed atomically by its sync script. Never edit it by hand.

## Conventions

- American English.
- Conventional Commits scoped by area: `feat(sse):`, `fix(transport):`, `refactor(client):`.
- Explicit `CodingKeys` for snake_case to camelCase mapping; wire types expose camelCase.
- All public types are `Sendable`; mutable shared state is actor-isolated or behind a lock.
- No force unwraps, and no `try!` outside test scaffolding where the invariant is unreachable.
- Swift Testing, not XCTest.
- Comments are self-contained and make sense to anyone reading the repository cold. Explain *why*, not the *what* the code already states, and never reference internal trackers or project phases.
