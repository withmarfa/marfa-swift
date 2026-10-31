# Marfa Swift SDK

[![Latest release](https://img.shields.io/github/v/release/withmarfa/marfa-swift)](https://github.com/withmarfa/marfa-swift/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/withmarfa/marfa-swift/ci.yml?branch=main&event=push&label=CI)](https://github.com/withmarfa/marfa-swift/actions/workflows/ci.yml?query=branch%3Amain)
[![License](https://img.shields.io/github/license/withmarfa/marfa-swift)](./LICENSE)

> **Early project.** Marfa is at version 0.0.x. Things will change without notice, and nothing is stable yet.

The Swift SDK for [Marfa](https://github.com/withmarfa/marfa), a home for your personal data that you run yourself. It is the Swift package `Marfa`, and it lets an iOS or macOS app work with a Marfa instance.

An app built on it keeps a working copy of the data it needs on the device. The app reads from that copy with or without a connection, queues its writes until it can send them, and follows changes from the instance. The package gives you Swift types, `async` calls, change streams and typed errors over Marfa's Rust core, which does the networking, storage and syncing.

## Requirements

- iOS 27 or macOS 27
- Xcode 27 or later, with Swift 6.4, on a Mac with Apple silicon

The core is built for Apple silicon only. In your app target's build settings, set Excluded Architectures for Any iOS Simulator SDK to `x86_64`, or some simulator builds fail to link.

## Install

In Xcode, choose File > Add Package Dependencies, enter `https://github.com/withmarfa/marfa-swift`, and add the `Marfa` product to your app's target. Use the version of the [latest release](https://github.com/withmarfa/marfa-swift/releases/latest).

In a `Package.swift`, add the package and the product:

```swift
.package(url: "https://github.com/withmarfa/marfa-swift", exact: "<latest release>"),
```

```swift
.product(name: "Marfa", package: "marfa-swift"),
```

Each release includes the core prebuilt, so your app needs no Rust toolchain.

The package has seven products:

- `Marfa`: the working copy, sign-in and folders.
- `MarfaAPI`: a client for the calls only the instance can answer. See [Call the server directly](#call-the-server-directly).
- `MarfaTypes`: the instance's wire types, generated from its `openapi.json`. `MarfaAPI` includes them.
- `MarfaTesting`: a working copy for tests and previews. See [Test and preview](#test-and-preview).
- `MarfaIcons`: draws an item type's icon. See [Draw a type's icon](#draw-a-types-icon).
- `MarfaBrandIcons`: the brand marks `MarfaIcons` draws for `simple-icons:` icons, as a product of their own so an app that leaves it out ships none. See [Draw brand marks](#draw-brand-marks).
- `MarfaTelemetry`: sends an app's errors and a fixed set of log events to a PostHog project the app chooses. See [Report errors and events](#report-errors-and-events).

## Example

This opens a working copy, fills it with the notes on your instance, and prints their titles. You need a running instance and a key that can read `core.note`; the [Quickstart](https://docs.marfa.so/quickstart) makes both.

```swift
import Marfa

let server = Server(url: serverURL, key: key)
let copy = try await WorkingCopy.open(store: storeURL, server: server)

_ = try await copy.hydrate(types: ["core.note"], tier: .library)

for note in try await copy.items.list(ListFilters(type: "core.note")) {
    print(note.title ?? "Untitled")
}
```

`storeURL` is where the working copy keeps its SQLite file, and `serverURL` is your instance's address. Keep `key` in the keychain between launches with `Keychain.system`; the copy holds it in memory and never writes it to its store.

## Fill a large library

Use `hydrate(types: ["*"], tier: .all)` for every type except `system.*`. Add a system type explicitly when needed, such as `["*", "system.view"]` for saved views. During a fill, compare `status().itemsListed` with `itemsExpected` when both are available; `items` also includes pinned rows and local creates.

Lists and searches return `Rows`, with `.complete`, `.partial` or `.stale` completeness. Read the rows as a collection, or use `.rows` when an API requires an array. Saved-view reads carry completeness too, including `LiveQuery<Rows<ViewGroup>>` for groups.

An interrupted hydration resumes when its slice is unchanged. Its report distinguishes `pages` read by this call from `pagesTotal`, including earlier calls, and says whether it `resumed` or why it `restarted`. When the server's event log no longer holds a copy's cursor, as can happen after a long sleep, `status().hydration` is `.stale`. While a `changes()` stream is held, the copy refills over its existing rows by itself and its streams carry on. After a call of your own throws `copyExpired`, or a stream is told `.stopped(copyExpired)`, read `status().hydration`: if it is `.stale`, hydrate the same slice again to refill. A copy runs one hydration at a time, so a hydration that starts while the refill runs waits for it, and returns the refill's report when the refill already filled the same slice under the same key. A `catchUp()` made meanwhile also waits, then catches up from where the refill left the copy. The report says `inPlace`. Item edits and creates remain queued through a fill or refill.

An app that keeps a large library in memory reads it whole once, then follows what changed rather than reading it all again. Take a cursor with `changes(since: nil)` before the first full read. After each change that `changes()` reports, call `changes(since:)` with the cursor you kept: reread the items it names with `items.get(_:includingBin:)` and the edges with `edges.get(_:)`, drop the removed ones, then keep the answer's `next`. When the answer is `.everything`, read the whole copy again. When a reread throws `hydrationIncomplete`, keep the earlier cursor and try again after `.refreshed(.hydrated)`. `items.links(in:)` reads the body links of many items in one call.

Set `fileBudget` when opening a copy, or leave it `nil` to keep the store's choice and use the default for a new store. `blobs.cache()` reports held bytes and attachment counts, including why some attachments are not held. `blobs.fetchKept()` fetches those attachments; they stay outside the cache budget. See the [Swift SDK reference](https://docs.marfa.so/swift-sdk) for progress, refill and file-policy details.

## Identify the connected instance

Read the server's public description to display its configured name:

```swift
let instance = try await server.instanceDescription()
print(instance.name)
print(instance.instanceId)
print(instance.version)
if let release = instance.release {
    print(release)
}
```

The result also includes `contract` and `features`. The server supplies `Marfa` when no display name is configured, and omits `release` for a build that is not a numbered release.

This call sends an anonymous JSON request through the core, preserves the server URL's path prefix, and needs no working copy or `config.manage` permission. It does not send `server.key` or read the keychain. Connection failures, HTTP refusals, redirects, and malformed descriptions throw `MarfaError`; a failed read does not produce a default description. Reading the description does not establish access to the instance's data or contract compatibility.

## Sign in

An app that people install signs in to their instance instead of asking them for a key. The owner approves the app in the browser, and the package keeps the sign-in in the keychain and renews it when the instance stops accepting its access token.

1. Choose a redirect address whose scheme is a reverse domain name you control, such as `com.example.notes:/signed-in`, and add the scheme to your app's `CFBundleURLTypes`.
2. Sign in, and open the working copy with the credential:

   ```swift
   import Marfa

   let authorization = try Authorization(
       server: serverURL,
       client: .init(
           name: "Notes",
           redirect: URL(string: "com.example.notes:/signed-in"),
           scopes: ["core.note:read", "core.note:write"]),
       service: "com.example.notes")

   let credential: Credential
   if let kept = try authorization.credential() {
       credential = kept
   } else {
       credential = try await authorization.signIn(presentingFrom: window)
   }
   let server = try Server(url: serverURL, credential: credential)
   let copy = try await WorkingCopy.open(store: storeURL, server: server)
   ```

   In SwiftUI, pass the `webAuthenticationSession` environment value to `signIn(using:)` instead.

An app without a browser, such as one on a TV or a command-line tool, uses `startDeviceSignIn()`: show the person its `userCode` and `verificationURL`, then wait on `credential()` while they approve on another device.

When the instance ends the sign-in, for example because the owner revoked the app, calls throw `MarfaError.signedOut` and the keychain no longer holds it; sign in again and open the copy with the new credential. `signOut()` deletes the sign-in from the keychain and revokes it at the instance.

To share the sign-in with your app's extensions, pass `keychain: Keychain(accessGroup:)` with an access group that every target's entitlements name.

## Call the server directly

Some calls only the instance can answer, such as registering an item type, managing keys and webhooks, or reading the audit log. The `MarfaAPI` product provides `Client`, which sends these calls straight to the instance with the server's key or sign-in. Add it to your app's target next to `Marfa`:

```swift
import MarfaAPI

let api = Client(server)
let title = Components.Schemas.FieldDefinition(_type: .string, required: true)
_ = try await api.register(
    itemType: .init(fields: .init(additionalProperties: ["title": title]), id: "app.example.entry"))
```

`Client` has no call that creates, gets, changes or deletes one item or edge, and none for search or events: those go through the working copy, so each item has one path. It offers no bulk changes either. Each call needs a connection: on a device that is offline, a call throws `MarfaError.noConnection` and sends nothing. Other failures throw the same `MarfaError` cases the working copy throws. When the instance refuses an expired access token, the client renews it once and sends the call again. It never follows a redirect, and it waits 30 seconds for the instance to send more; pass `Client(_:timeout:)` a longer time for a call such as `runHousekeeping(_:)` that answers only when its work is done.

## Read where an item stands

A type with a `status` field, such as `core.task`, declares the words its items can hold, and puts each word in one of four groups that every type shares: `not_started`, `in_progress`, `completed` and `canceled`. `StatusGroup` names the four, so an app can tell what is open, active or finished without knowing a type's own words. `ItemType.statusWords` lists the words in order, each with its group, and `statusField` names the field. A subtype lists its parent's words first and then the ones it adds.

```swift
let task = try await copy.catalog.itemType("core.task")
task.statusWords                          // not_started, in_progress, completed, canceled
task.statusGroup(of: "completed")         // .completed

let group = try await copy.catalog.statusGroup(of: item)   // read with the item's own type
let groups = try await copy.catalog.statusGroups(of: items)
```

`statusGroup(of:)` throws `MarfaError.notFound` for an item whose type the catalog does not hold, as `itemType(_:)` does. `statusGroups(of:)` gives `nil` for that item and reads the rest.

The group is `nil` for an item that holds no status, holds a word its type does not declare, or has a type with no status field. A write that changes the status to a word the type does not declare throws `MarfaError.validation` with the code `invalid_properties`. An edit that leaves the field alone does not.

A listing, a view and a folder select by group with the `status_group` term in a `filter`. This lists the open items of every type that has a status field:

```swift
let open = try await copy.items.list(
    ListFilters(filter: "status_group neq \"completed\" AND status_group neq \"canceled\""))
```

An item in no group matches neither `eq` nor `neq`; `status_group not_exists` selects it. The server refuses a group name that is not one of the four, with `MarfaError.validation`.

`core.event` has a `status` of its own that is not a status field: one of three fixed values, with no groups. `EventStatus` names them. A subtype cannot change them, so `copy.catalog.eventStatus(of: item)` reads the status of an item of `core.event` or of a type that descends from it, such as one a connector declares, and gives `nil` for any other item.

## Draw a type's icon

An item type carries one icon, an [Iconify](https://iconify.design) ID, `<set>:<name>`, from a set Marfa pins: `lucide:book-open` for a general icon from [Lucide](https://lucide.dev), or `simple-icons:github` for a brand mark from [Simple Icons](https://simpleicons.org). A bare name such as `book-open` is not an ID. `ItemType.icon` holds the ID the core resolved: the owner's own choice for the type or the nearest type that has one, else the nearest author's. It is `nil` when no type in the chain sets one.

The `MarfaIcons` product draws it:

```swift
import MarfaIcons

TypeIcon(type)                 // from an ItemType
TypeIcon(id: type.icon)        // from an ID
Image(typeIcon: type.icon)     // where a view needs an Image
```

Apple apps draw SF Symbols, so `TypeIcon` uses the SF Symbol that stands for a `lucide:` ID. For an ID with no good match it draws Lucide's own artwork, shipped in the package as a template image. Both tint with `foregroundStyle`, follow light and dark appearance, and size with the surrounding font. A type with no icon draws a fallback symbol, and so does an ID this version of the package cannot draw: a bare name, an unknown set, an unknown name, or a `simple-icons:` ID in an app that has not added `MarfaBrandIcons`. None of them fails; a server newer than the SDK can send an ID the SDK does not know.

`MarfaAPI` sets and clears the owner's icon, and answers the type as the server now reads it, so your app can draw the new icon at once:

```swift
let type = try await api.set(icon: "lucide:scale", forType: "app.example.decision")
_ = try await api.clearIcon(ofType: "app.example.decision")
```

Either call needs the `schema.write` permission and write on the type, and works on a type Marfa ships as well as your own. The server refuses an ID that is not in a pinned set, a bare name included, with `MarfaError.validation` and the code `invalid_schema`. Clearing a type that has no owner icon succeeds and changes nothing.

A working copy takes the change when its connection to the server reopens, so another device shows it within about two minutes.

### Draw brand marks

The Simple Icons artwork is about 4.8 MB of SVG across 3,467 marks, so it is a product of its own. An app that wants brand marks adds `MarfaBrandIcons` and registers it once at launch, before any icon draws:

```swift
import MarfaBrandIcons

@main struct NotesApp: App {
    init() { MarfaBrandIcons.register() }
    var body: some Scene { /* ... */ }
}
```

Registering is how `TypeIcon` finds the artwork without `MarfaIcons` depending on it. A brand mark is a template image, so it tints with `foregroundStyle` like every other icon. An app that never adds the product ships none of the artwork, and a `simple-icons:` ID draws the fallback symbol.

### Where the icons come from

`Sources/MarfaIcons/LucideSymbols.swift` maps each `lucide:` ID to an SF Symbol. It was seeded from [rosetta-icons](https://github.com/arfct/rosetta-icons) and then checked by hand, with the two glyphs side by side; a pair that is close but says something else is left out. `scripts/icons.mjs` reads the icon lists marfa generates at the pinned commit, `icon-set-lucide.json` and `icon-set-simple-icons.json`, and ships the SVG from the `@iconify-json/lucide` and `@iconify-json/simple-icons` releases they name: for every Lucide icon the table leaves out, and for every brand mark. It also writes `LucideIconSet` and `SimpleIconsIconSet`, so the table, the artwork and the lists share one pin. Tests fail when the table names an icon the pinned list lacks, when a symbol does not exist on the SDK, when an icon has neither a symbol nor artwork, when a file of artwork is from another release than its list names, or, with `MARFA_MONOREPO` set to the checkout at the pin, when a list differs from the one marfa generates. Edit the table, then run `scripts/icons.mjs` after `scripts/core.sh`. Licenses are in [`THIRD-PARTY-NOTICES.md`](./THIRD-PARTY-NOTICES.md).

To let a person choose an icon, offer `LucideIconSet.ids`, and `MarfaBrandIcons.ids` when the app links it: the IDs the server accepts at the pinned releases. Draw each with `TypeIcon(id:)`; `Client.set(icon:forType:)` saves the choice.

## Test and preview

The `MarfaTesting` product provides a working copy for tests and SwiftUI previews, without a store, a server, or a call into the Rust core. Add it to test targets. Its module compiles empty in a release build, so nothing from it ships; wrap its uses in `#if DEBUG`. Pass `fake.copy` wherever a view model accepts a `WorkingCopy`:

```swift
#if DEBUG
import MarfaTesting

#Preview {
    let fake = WorkingCopy.fake(items: [note], itemTypes: [noteType])
    NotesView(model: NotesModel(copy: fake.copy))
}
#endif
```

Use `FakeCopy` to record writes, choose drain verdicts, and send changes on `changes()`. Unsupported calls throw `FakeCopyError.unsupported`. The `FakeCopy` API documentation lists the supported calls.

The fake takes the status words of the types you give it and refuses a write that changes a status to a word the type does not declare, as the real copy does. It does not run a `filter`, `status_group` included, and it does not declare a type with a status field, so both throw `FakeCopyError.unsupported`.

## Handle errors

Every call throws `MarfaError`. Three properties say what an error means, so an app does not need its own list of cases:

- `isOffline`: the server could not be reached, or its answer did not arrive. A write may still have reached the server.
- `isKeyRefusal`: the key or sign-in no longer works. Ask the person to sign in again, or get a new key. A `forbidden` error is never a key refusal: the key is valid but lacks a permission.
- `isTransient`: asking again later can clear it. No key refusal is transient, and every offline error is.

A store that another build of Marfa made is refused with `wrongSchema`, which carries the number of writes in it that the server has not taken. To replace such a store with an empty one, open it with `ifRefused: .replace`. The store is replaced only when it holds no unsent writes; otherwise the open throws `wrongSchema` with the count and leaves the store as it is. To give up those writes, show the person the count, then call `WorkingCopy.remove(store:unsent:)` with it and open the store again.

```swift
let copy = try await WorkingCopy.open(store: storeURL, server: server, ifRefused: .replace)
```

## Report errors and events

The `MarfaTelemetry` product sends an app's errors, and a fixed set of log events, to a PostHog project. It has no third-party dependency, **no token and no destination of its own**, and does nothing until the app configures it and turns it on, so an app that does not import it carries none of it.

```swift
import Marfa
import MarfaTelemetry

Telemetry.shared.configure(
    Telemetry.Configuration(
        destination: try Telemetry.Destination(host: posthogHost, projectToken: projectToken),
        serviceName: "notes",
        serviceVersion: appVersion))
Telemetry.shared.isEnabled = reportingIsOn

Telemetry.shared.report(error, during: "drain")
Telemetry.shared.log("drain_finished", attributes: ["pending": 3, "complete": true])

await Telemetry.shared.flush()  // when the app quits
```

- **Destination.** An `https` PostHog host and a project token, or an `http` loopback address for a test. The `Telemetry.Destination` initializer throws `ConfigurationError` for anything else, such as an address with a user name.
- **Errors.** `report(_:during:)` posts one `$exception` event to `<host>/i/v0/e/`, as the `marfa` command line does: no stack frames, no person, no location lookup. A `MarfaError` is described by `MarfaError.fixedText`, a type and a sentence fixed in the source by an exhaustive `switch`, so a new case fails to compile until someone writes its sentence. `report(type:sentence:during:)` does the same for an error of the app's own.
- **Loops.** A failure that repeats is not reported every time: one exception for each type and operation in 60 seconds, and 30 in an hour in all. Each exception that goes out carries `dropped_since_last`, the number withheld since the previous one.
- **Logs.** `log(_:level:attributes:)` queues an OTLP/HTTP JSON record for `<host>/i/v1/logs`. Records go out at 50, or after 30 seconds, or on `flush()`, which waits at most 2 seconds. At most 500 wait: the oldest is dropped, and the next batch counts the drops.
- **Never sent.** Item text, titles, tags, item ids, natural keys, keys or credentials, the instance's identifier or the server's address, file paths, search text, and any `message` or `localizedDescription`. A name, an operation and a sentence are `StaticString`s, and an attribute is a number, a boolean or a `StaticString`, so these cannot be passed by accident.
- **Switch.** `isEnabled` is off until the app turns it on. Turning it off drops everything queued, stops a send under way and sends nothing more.
- **Sending.** One ephemeral `URLSession` with no cookies, cache, credentials or redirects, and one attempt for each post, which gives up after 5 seconds without data or 10 seconds in all. It runs away from the main actor. A call never waits for the network.

The [Telemetry guide](https://docs.marfa.so/run/telemetry#what-apps-send) says what Marfa's own apps send and how to turn it off. The product declares the diagnostic data it can send in its own `PrivacyInfo.xcprivacy`.

## Learn more

The documentation is at [docs.marfa.so](https://docs.marfa.so).

- [Swift SDK](https://docs.marfa.so/swift-sdk): the working copy, items, queued writes, change streams, live queries, conflicted copies and folders on a Mac.
- [Build an app with Swift](https://docs.marfa.so/build/swift-app): a tutorial that builds a SwiftUI app for iPhone and Mac.
- [Devices](https://docs.marfa.so/devices): how an app keeps a working copy and sends its changes.
- [Write safely](https://docs.marfa.so/build/write-safely): versions, conflicts and retries.
- [Sync a folder](https://docs.marfa.so/run/sync-a-folder): keep a directory on your Mac in step with your notes.
- [API reference](https://docs.marfa.so/api-reference): the HTTP API the SDK is built on.

The server, the core and the contract are in [withmarfa/marfa](https://github.com/withmarfa/marfa).

## Build from source

To work on the package itself, build its pinned core first, which needs the Rust toolchain and Node.js 22 or later:

```sh
scripts/core.sh
swift build
swift test
```

`Examples/MarfaSample` is a SwiftUI sample app; run `xcodegen generate` in that folder to make its project. [`AGENTS.md`](./AGENTS.md) holds the rules for working in this repository.

## License

[Apache License 2.0](./LICENSE)
