# marfa-swift

The Swift package `Marfa`, for iOS 27 and macOS 27 on Apple silicon, built with Xcode 27 or later. It embeds `MarfaCore`, the Rust engine from `withmarfa/marfa`, which holds a working copy of a slice of one Marfa server, queues writes for it with their verdicts, follows its events and keeps blobs. This package gives the core Swift types, `async` calls, change streams and typed errors.

## Installing a released version

Add the package by URL in Xcode, or in a `Package.swift`:

```swift
.package(url: "https://github.com/withmarfa/marfa-swift", from: "0.0.1")
```

and depend on the `Marfa` product, plus `MarfaTypes` for the wire types. Each release carries the core prebuilt, so an app needs no Rust toolchain. The core is built for arm64 only, so an app's simulator builds set `EXCLUDED_ARCHS[sdk=iphonesimulator*]` to `x86_64`.

For the API of a published version, read this README at that version's Git tag. The tutorial below uses this source checkout built at `core.pin`.

## Building and using the source checkout

Clone this repository and build its pinned core before adding the checkout to your app:

```sh
git clone https://github.com/withmarfa/marfa-swift.git
cd marfa-swift
```

Build from the checkout:

```sh
scripts/core.sh   # builds the core at core.pin and copies it in; needs the Rust toolchain and Node.js 22 or later
swift build
swift test        # live tests run when MARFA_API_URL and MARFA_API_KEY name a server
```

Add the built checkout as a local package in Xcode, or use a local dependency in an app beside it:

```swift
.package(path: "../marfa-swift")
```

Depend on the `Marfa` product, plus `MarfaTypes` when you need the wire types. A source checkout needs its local framework built by `scripts/core.sh`; use the local dependency after that build rather than a remote branch dependency.

## Get a key for your app

Use the [Marfa CLI](https://github.com/withmarfa/marfa/tree/main/core#the-binary) against your own server. Sign in as its owner and approve the code in the browser:

```sh
marfa --url https://marfa.example login
```

Mint a working key for a reading-list app. The owner must be able to mint keys, write this type, and grant access to the metadata families named here:

```sh
marfa keys create --label "Reading list" --source app.readinglist \
  --type-permission app.readinglist.entry=write \
  --metadata-permission types=write \
  --metadata-permission tags=write \
  --default-tier library
```

Keep the returned key in the app's keychain with `Keychain.system.save(key:service:account:)`, and read it with `key(service:account:)`. The app also saves the server URL in its settings. Pass both to `Server(url:key:)`; the working copy keeps the key in memory and never writes it to its store. This key can read and write the app's type, register its missing definition, and write tags. It does not grant access to other item types. If the owner registers the type separately, omit `--metadata-permission types=write`.

## Declare and use an app type

An app can declare its types before it reaches a server. Each declaration is a JSON type definition. The following definition can also be registered by the owner through the CLI:

```sh
marfa types register --body '{"id":"app.readinglist.entry","fields":{"title":{"type":"string","required":true}}}'
```

Identifiers use lowercase dotted segments. An app identifier has exactly three segments, `app.<app-name>.<type>`, such as `app.readinglist.entry`. A publisher identifier such as `com.example.bookmark` can have more segments. The server refuses registration under the reserved roots `core`, `system`, and `marfa` for every key. Apps can use built-in types such as `core.note` without declaring or registering them. See the [type identifier and registration rules](https://github.com/withmarfa/marfa/blob/main/conformance/spec/types.md#identifiers) for the full grammar and reserved names.

```swift
import Marfa

let copy = try await WorkingCopy.open(store: storeURL, server: Server(url: serverURL, key: key))
try await copy.declareTypes([
    #"{"id":"app.readinglist.entry","fields":{"title":{"type":"string","required":true}}}"#
])
_ = try await copy.items.create(
    Draft(type: "app.readinglist.entry", properties: ["title": "Read this"], tier: .library))
let hydrated = try await copy.hydrate(types: ["app.readinglist.entry"], tier: .library)
let items = try await copy.items.list()
if let item = items.first {
    _ = try await copy.items.update(item.id, Edit(.merge(["title": "Read next"]), baseVersion: item.version))
}
let report = try await copy.queue.drain()
// Present refused or blocked verdicts before deciding what to do with them.
_ = try await copy.queue.forgetAnswered()
_ = try await copy.catchUp()

for await change in copy.changes() {
    // Read again what the change touched.
}
```

`declareTypes(_:)` replaces the app's **whole declaration set**. Pass every type the app still declares on each call; an empty array clears the declarations. `declaredTypes()` reads the normalized JSON stored in the copy. Before the first hydration, declared types and the types Marfa ships validate queued creates offline. Reopening the store keeps the declarations and queued writes.

Hydration registers declarations the instance does not hold when the key has write access to the type and `metadata.types:write`. A completed `HydrateReport` lists new registrations in `registeredTypes` and refusals in `unregisteredTypes`, each with its `id`, server `code`, and `message`. A refusal keeps the declaration and queued content. If the requested slice names an exact type the instance still lacks, hydration throws `unknownType`; register that type with the required permissions before requesting it again.

A tier separates lasting material (`library`) from an incoming stream (`feed`). The CLI's default is `library`, so this example hydrates and writes there. The sample app deliberately uses `feed`; to see its notes in CLI results, request that tier. Set the tier on a `Draft` when it should differ from the copy's slice. Without one, the copy uses its slice's tier, `library` in a slice of both tiers, or `library` before its first hydration, and sends that tier explicitly. A create whose `source` and `sourceId` name an item the copy holds keeps that item's tier instead, so saving it again does not move an item the person triaged. The key's default does not choose a queued create's tier. A create outside the slice remains held as a pin until the app unpins it.

An app that shows an inbox (`feed`) beside the person's record (`library`) holds both in one copy by hydrating with `tier: .all`. An item is in exactly one tier, so `Item.tier` and `Draft.tier` stay a `Tier`; the slice's own setting is a `SliceTier`. Triage is an edit that moves the item's tier, and the item stays in the copy at its new tier, offline too:

```swift
_ = try await copy.hydrate(types: ["core.note"], tier: .all)
let inbox = try await copy.items.list(ListFilters(tier: .feed))
if let item = inbox.first {
    _ = try await copy.items.update(item.id, Edit(baseVersion: item.version, tier: .library))
}
let record = try await copy.items.list(ListFilters(tier: .library))
```

In a copy that holds one tier, the same item leaves the copy once the server answers the move.

Nothing runs on its own. The app decides when to `hydrate`, when to `catchUp`, when to `queue.drain()` its writes, and when to `queue.forgetAnswered()`; answered writes stay in the queue, with the server's answers, until it does, and blocked or dead writes stay until released or withdrawn. A held `changes()` stream follows the server's events; if it stops with an error, the next hydration or catch-up starts it again.

Each queued write carries its `verdict` once the server answers it. A write held behind another that has no answer yet is `waiting`, with no verdict, and goes once that write is answered; a `blocked` verdict is a stop the app may have to act on, by releasing or withdrawing it. A `refused` verdict carries a typed `Refusal`: the server's code and message, each property it would not take and why, whether the row is in the bin, and any permission the key lacks. A refused write that carried content keeps it in `body` through `forgetAnswered()`, so the app can offer it back to the person, until `queue.discard(_:)` takes it out. A drain's report lists each write it answered with the item or edge it wrote, and a held `changes()` stream is told each one as `.answered`. On a store that has never hydrated, the writer's stream receives local write and declaration notifications; it starts following server events with the first hydration.

The drain report separates requests the server `answered`, writes still `undelivered`, writes settled `unsent`, and requests that were `unmade`. `unavailable` says why the pass ended without reaching the rest; `stopped` names a refused credential that parked the queue. A network outage leaves undelivered writes waiting without counting a refusal.

Cancel a Task running `hydrate`, `catchUp`, or `queue.drain()` to request that call to stop. The package raises the core's per-call stop flag. When the core observes the stop, the call throws `MarfaError.canceled`. A canceled task does not start a new call. A running network request can finish or reach its timeout before the core observes cancellation. An interrupted hydration may need another hydration before reads resume; catch-up keeps its reached cursor, and a drain keeps unanswered writes queued under their original idempotency keys. Inspect the queue and drain again when the app is ready. Cancellation of one call does not cancel another.

`MarfaError.code()` returns the canonical error name shared with the core and CLI, such as `validation` or `canceled`. A server refusal's associated `code` remains the server's specific code, such as `validation_error`.

Hydration normally holds the edges going out from items in its slice. To hold an edge type whole, whichever of its endpoints the item slice holds, pass `edgeTypes`, such as `copy.hydrate(types: ["core.note"], tier: .feed, edgeTypes: ["attached-to"])`. `copy.pin(id)` reads and holds one item outside the slice; `copy.unpin(id)` lets it go when the slice and queued writes do not need it. Both return whether the item is pinned now and whether it was pinned before, and notify change streams as `.refreshed(.pinned)` or `.refreshed(.unpinned)`.

`ListFilters` and `SearchFilters` carry `filter`, an expression in the server's listing grammar, and `beneath`, the root of a held `parent-of` subtree. A local filter cannot use a back-reference condition. These options narrow what the copy already holds.

`Status.instanceId` names the instance the copy was hydrated from. `copyExpired(reason:message:)` means hydration is needed while the queue is kept. Structural changes such as a newly registered type, or a change to read access, expire a certified view with `read_view_changed`; a held `changes()` stream reports the cause through `.stopped(.copyExpired(reason:message:))`. A store whose shape this build cannot read throws `wrongSchema(path:reason:unsent:message:)`, including the count of pending writes where its queue is readable. A refusal without the server's contract throws `unnamed(status:message:)` when read directly; a drain reports such a gateway refusal as unavailable and keeps its writes. A success missing the contract is refused as `contractMismatch`.

`storageFull(message:)` identifies exhausted local storage, while `io(message:)` preserves another local I/O failure. `signedOut(origin:message:)` and `noKeychain(message:)` retain credential failures without inventing a server refusal. `redirected(origin:status:location:message:)` preserves the actual redirect response and its optional destination; the client does not follow it. `contractMismatch` carries an optional HTTP status, which is nil when the failure supplies none. These causes remain typed when reported by a stopped change stream.

The package is not built for library evolution, so its enums are exhaustive: switch over them without `@unknown default`. A case added in a later version stops the app's build at each switch that has to handle it, which is intended.

`copy.catalog` reads the item types the copy holds, with the fields each inherits, and its edge types, with their reverse names, custom ones included. It answers from the copy alone, so it works offline. Before the first hydration, it holds Marfa's built-in catalog and the app's declarations; hydration replaces that with the instance's catalog. `Status.catalogVersion` tracks changes to the server catalog and stays nil until the first hydration; local built-in and declared types do not assign a version. The writer's held `changes()` stream is told `.refreshed(.catalog)` for a declaration or a server catalog change, or `.refreshed(.hydrated)` for a hydration. A reader's stream reports `.saved` when SQLite's data version changes.

`MarfaTypes`, a second product, holds the server's wire types, generated from the pinned `openapi.json`, for reading answers the working copy does not hold. Generation fails on any diagnostic instead of silently dropping an unsupported schema. Nullable reference unions use `MarfaNullable.null` for an explicit JSON null; an absent optional omits the field. For example, `Operations.UpdateKey.Input.Body.JsonPayload(enforcementOverride: .null)` clears an override, while leaving `enforcementOverride` unset makes no change.

A blocked verdict can carry the structured refusal and missing grant. Drain reports preserve the core’s retry delay, including when an intermediary answers without the server’s contract header.

## Read and edit items

An `Item` carries `title` and `body`, read from the properties its type's display hints name: `core.event` shows its `description` as its body, a type that names a body field of its own shows that one, and a type whose hints name neither uses `title` and `body`. Use them rather than reading `properties["title"]`:

```swift
for item in try await copy.items.list(ListFilters(type: "core.event")) {
    print(item.title ?? "Untitled", item.body ?? "")
}
```

`properties` is a `JSONObject`, which keeps its keys in the order the server answers them. A create puts the fields the type declares first, in the type's order, then the rest in the order they were written. A `.merge` edit moves no key and adds each new one after them, and a `.replace` edit keeps the order it sends. Any key that is an array index, such as `2024`, comes first of all. The copy shows the same order before a write is sent as after the server answers it, unless another device's write reaches the item first. Iterate it, or read `keys`, to lay out an item as a document. `JSONObject(json:)` and `JSONValue(json:)` read JSON text in order, and `json()` writes it back in order; `JSONEncoder` and `JSONDecoder` do not keep key order.

An `Edit` says how its properties meet the item's. `.merge` replaces each property it names and leaves the rest; `.replace` makes them the item's whole properties, so a property it leaves out is cleared. **`.replace` is the way to drop a property**: a `null` under `.merge` clears nothing, because the server drops it and the copy does too, and a `null` for an optional field in a `Draft` leaves the field out of the new item. A `.replace` sent through `updateAsRead(_:_:)`, at a version older than the one the copy holds, is merged as `.merge` is. An edit can also move the item to another type or tier:

```swift
guard let item = try await copy.items.get(id) else { return }
_ = try await copy.items.update(id, Edit(.merge(["title": "Renamed"]), baseVersion: item.version))
_ = try await copy.items.update(id, Edit(.replace(["body": "Only this"]), baseVersion: item.version))
_ = try await copy.items.update(id, Edit(baseVersion: item.version, type: "core.task", tier: .feed))
```

Each edit is queued and shown at once, offline included. A type the copy's catalog does not hold throws `unknownType` and queues nothing. A retype changes what the copy's read view covers, so once the server answers it the drain throws `copyExpired(reason: "read_view_changed", …)`: the write is answered, and the app hydrates again.

## Recently deleted

`items.delete(_:)` moves an item to the bin. The bin itself is read from the server, a page at a time, newest change first, and nothing read from it is held in the copy. Offline, `bin` throws `network`; the copy never answers for it. The server answers no time an item went to the bin, so its `updatedAt` stands for it, though a write to an item in the bin moves it too.

```swift
var page = try await copy.items.bin(type: "core.note")
while true {
    for item in page.items { print(item.title ?? item.id, item.updatedAt) }
    guard let next = page.nextCursor else { break }
    page = try await copy.items.bin(type: "core.note", after: next)
}
```

`items.restore(_:)` brings an item back. One the copy holds shows as restored at once; one it does not, such as an item read from the bin, is restored by id: the restore is queued, survives a restart, and the item arrives in the copy once the server answers, where the slice takes it. `pin(_:)` of an item in the bin throws `notFound(code: "trashed", …)`.

`items.purge(_:version:)` destroys an item in the bin for good. It is never queued: it is sent at once, and needs the server and a key holding `items.purge`. Pass the version the person was shown, such as a bin item's; without one, the copy's own is used, and an item the copy does not hold throws `notFound(code: "not_held", …)`. An item the copy shows outside the bin throws `validation(code: "invalid_transition", …)`, and one with a write still waiting throws `invalid`. On any failure the copy and the queue stay as they were.

```swift
try await copy.items.purge(item.id, version: item.version)
```

## Keep a copy in sync

Nothing runs on its own, so an app drives the copy through its life:

1. **On first launch, or when `status().hydration` is `never` or `expired`,** call `hydrate(types:tier:)`. It replaces the copy with the slice and keeps the queue.
1. **When the app starts or comes to the front,** call `catchUp()` to apply what changed while it was away, then `queue.drain()` to send what it queued.
1. **While a screen shows server data,** hold a `changes()` stream. It follows the server's events and tells each one as `.server`.
1. **When the stream tells `.serverUnreachable(error)`,** show the app as offline; `error` is typed, such as `network`, `rateLimited` or `server`. The follow keeps asking at a falling rate. Writes still queue. The copy tells this once until the server is reached again, however often the follow starts again around a catch-up or a hydration, and a stream added meanwhile is told it first.
1. **When it tells `.serverReachable`,** call `queue.drain()` to send what waited, and show the app as online again. A hydration, a catch-up or a drain that reaches the server tells it too.
1. **After each write the person makes,** call `queue.drain()` when the app is online; a drain that cannot reach the server leaves the writes waiting, uncounted.

```swift
for await change in copy.changes() {
    switch change.origin {
    case .serverUnreachable(let error): showOffline(error)
    case .serverReachable:
        showOnline()
        _ = try? await copy.queue.drain()
    case .stopped(.copyExpired):
        _ = try? await copy.hydrate(types: ["core.note"], tier: .library)
    case .stopped(.unauthorized), .stopped(.signedOut):
        askForANewKey()
    default:
        refresh(change.itemId)
    }
}
```

A stream that tells `.stopped` has ended its follow until the next hydration or catch-up. `copyExpired` means the copy can no longer be kept current from where it is, after the server's log moved past it, another instance answered at its address, or its read view changed, such as after a retype or a type registered: hydrate again, and the queue survives. `unauthorized` means the server refused the key, and `signedOut` that a signed-in credential is gone: get a new key and pass it to `useKey(_:)`, and the follow starts again with it.

## Sync a folder on a Mac

A folder is a directory whose files Marfa keeps in step with the search a `system.folder` item on the server describes. `Folders` manages them on macOS through the same core and the same registry as `marfa folders`, so a folder added from an app appears in `marfa folders list`, and one added from the command line appears in `folders.list()`.

1. Create the folder's settings on the server, for example with `marfa folders create --title Notes --search '{"types":["core.note"]}'`, and note the returned item ID.
1. Add the directory. A new folder's first sync waits for you to confirm it, so `sync(_:)` reads the folder and says what it will do, and nothing is written into the directory or sent until `confirmFirstSync(in:)`:

    ```swift
    import Marfa

    let folders = Folders(server: Server(url: serverURL, key: key))
    let notes = URL(filePath: "/path/to/Notes", directoryHint: .isDirectory)
    _ = try await folders.add(notes, following: folderID)

    switch try await folders.sync(notes) {
    case .awaitingConfirmation(let plan):
        // `plan.write` files go into the directory and `plan.send` go to the server. Of the files written,
        // `plan.beside` take a path a file already has: both stay, and one gets a number in its name.
        try await folders.confirmFirstSync(in: notes)
    case .synced:
        break
    }
    ```

    To cancel instead, call `remove(_:)`, which leaves the files where they are.

1. Sync it:

    ```swift
    guard case .synced(let synced) = try await folders.sync(notes) else { return }
    if synced.catchUpError != nil {
        // The server was out of reach; local edits wait and go at the next sync.
    }
    ```

1. Read what the sync held back and what the server did with your edits. `pass.flagged` lists each file the scan or the pull held, with why. For a file the pull didn't write, `item` is the ID of the item it stands for. `pass.drain` counts every write the sync sent, including the placements of the files the pull wrote, and its verdicts say when the server kept its own text and put an edit's text in a copy:

    ```swift
    for file in synced.pass.flagged {
        print(file.path, file.flag, file.reason, file.item ?? "")
    }
    for write in synced.pass.drain.verdicts {
        if case .conflicted(let copy, _)? = write.verdict {
            // The edit of `write.itemId` lost to a newer one; its text is in the item `copy`.
        }
    }
    ```

1. Read where each file stands. `status(of:)` reads the folder's own store and asks the server nothing:

    ```swift
    let status = try await folders.status(of: notes)
    for file in status.files where file.state != .inStep {
        print(file.path, file.state, file.reason ?? "")
    }
    if status.paused.isPaused {
        // A large removal waits: call confirmRemoval(in:) or restoreRemoval(in:).
    }
    ```

To keep a folder in step while the app runs, as `marfa folders watch` does, iterate `watch(_:)`, and call `stop()` when you're done. The sequence ends after `stop()`, or throws a `MarfaError` when the watch fails, such as `unauthorized` when the server refuses the key:

```swift
let watch = try await folders.watch(notes)
for try await event in watch {
    if case .passed(let pass) = event { print(pass.scan.created, "created") }
}
```

One process works a folder at a time. While a watch, or `marfa folders watch`, holds a folder, the other calls on it throw `MarfaError.readingHandle`; `status(of:)` still answers. `remove(_:)` throws `invalid` while writes wait to be sent, except for a first sync still waiting, and keeps the files when it removes the folder. `watch(_:)` throws `MarfaError.firstSyncWaiting` until the first sync is confirmed. Folders are available on macOS only. The registry is the file `MARFA_FOLDER_REGISTRY` names, or `~/Library/Application Support/Marfa/folders.json`; a sandboxed app has its own home directory, and so its own registry.

## Keys

`Server.fromEnvironment()` reads `MARFA_API_URL` and `MARFA_API_KEY`, for agents and tests, and throws when only one is set. An app keeps a person's key between launches with `Keychain.system` (`save`, `key`, `delete`), under a service and account it chooses. The working copy never writes the key to its store.

`copy.useKey(_:)` gives an open copy a new key: it closes the store and opens it again with the new key, and the copy, its parts and its held `changes()` streams carry on. The core has no call to change a key in place, so the store is reopened. That cannot happen while a call is running, so `useKey` waits for the slowest running call, and until the new key is in use every call on the copy throws `invalid`: ask again. A copy opened without a server throws `noServer`. If the store cannot be opened again the error is thrown and the copy is closed.

## Closing

`copy.close()` ends every `changes()` stream, stops what feeds them, and releases the store, so another opener can take the writer role once it returns. Calls already running finish first, so it takes as long as the slowest of them. Every call made after it begins, on the copy or any part of it, throws `MarfaError.closed`; a call racing `close()` either completes or throws that. A second `close()` returns only once the store is released.

## The sample

`Examples/MarfaSample` is a SwiftUI app for macOS and the iOS simulator; `xcodegen generate` in that folder makes its project. `--scenario hydrate|write|drain|catch-up` runs one phase unattended and exits nonzero when a check fails. CI runs all four with the server stopped between `hydrate` and `write`.

`AGENTS.md` has the rules for working in this repository.
