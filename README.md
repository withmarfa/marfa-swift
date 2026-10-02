# marfa-swift

The Swift package `Marfa`, for iOS 27 and macOS 27 on Apple silicon, built with Xcode 27 or later. It embeds `MarfaCore`, the Rust engine from `withmarfa/marfa`, which holds a working copy of a slice of one Marfa server, queues writes for it with their verdicts, follows its events and keeps blobs. This package gives the core Swift types, `async` calls, change streams and typed errors.

## Installing

Add the package by URL in Xcode, or in a `Package.swift`:

```swift
.package(url: "https://github.com/withmarfa/marfa-swift", from: "0.0.1")
```

and depend on the `Marfa` product, plus `MarfaTypes` for the wire types. Each release carries the core prebuilt, so an app needs no Rust toolchain. The core is built for arm64 only, so an app's simulator builds set `EXCLUDED_ARCHS[sdk=iphonesimulator*]` to `x86_64`.

## Building

Working on the package itself builds the core from source:

```sh
scripts/core.sh   # builds the core at core.pin and copies it in; needs the Rust toolchain
swift build
swift test        # live tests run when MARFA_API_URL and MARFA_API_KEY name a server
```

## Using it

```swift
import Marfa

let copy = try await WorkingCopy.open(store: storeURL, server: Server(url: serverURL, key: key))
_ = try await copy.hydrate(types: ["core.note"], tier: .feed)

let write = try await copy.items.create(
    Draft(type: "core.note", properties: ["title": "Hello", "body": "First note"], tier: .feed))
let report = try await copy.queue.drain()

for await change in copy.changes() {
    // Read again what the change touched.
}
```

Set the tier on each `Draft`. Without one, the key's default tier decides, and an item outside the copy's slice drops out of it once the server's event for it arrives.

Nothing runs on its own. The app decides when to `hydrate`, when to `catchUp`, when to `queue.drain()` its writes, and when to `queue.forgetAnswered()`; answered writes stay in the queue, with the server's answers, until it does, and blocked or dead writes stay until released or withdrawn. A held `changes()` stream follows the server's events; if it stops with an error, the next hydration or catch-up starts it again.

Each queued write carries its `verdict` once the server answers it. A write held behind another that has no answer yet is `waiting`, with no verdict, and goes once that write is answered; a `blocked` verdict is a stop the app may have to act on, by releasing or withdrawing it. A `refused` verdict carries a typed `Refusal`: the server's code and message, each property it would not take and why, whether the row is in the bin, and any permission the key lacks. A refused write that carried content keeps it in `body` through `forgetAnswered()`, so the app can offer it back to the person, until `queue.discard(_:)` takes it out. A drain's report lists each write it answered with the item or edge it wrote, and a held `changes()` stream is told each one as `.answered`. On a store that has never hydrated, a held stream waits quietly and starts following with the first hydration.

The package is not built for library evolution, so its enums are exhaustive: switch over them without `@unknown default`. A case added in a later version stops the app's build at each switch that has to handle it, which is intended.

`copy.catalog` reads the instance's item types, with the fields each inherits, and its edge types, with their reverse names, custom ones included. It answers from the copy alone, so it works offline. The first hydration brings the catalog; before it, every read throws `noCatalog` rather than answering no types. `Status.catalogVersion` moves whenever a hydration, a catch-up or a held stream changes the catalog, and a held `changes()` stream is told `.refreshed(.catalog)`, or `.refreshed(.hydrated)` for a hydration.

`MarfaTypes`, a second product, holds the server's wire types, generated from the pinned `openapi.json`, for reading answers the working copy does not hold.

## Keys

`Server.fromEnvironment()` reads `MARFA_API_URL` and `MARFA_API_KEY`, for agents and tests, and throws when only one is set. An app keeps a person's key between launches with `Keychain.system` (`save`, `key`, `delete`), under a service and account it chooses. The working copy never writes the key to its store.

`copy.useKey(_:)` gives an open copy a new key: it closes the store and opens it again with the new key, and the copy, its parts and its held `changes()` streams carry on. The core has no call to change a key in place, so the store is reopened; calls made in that moment throw `invalid`, and if the store cannot be opened again the error is thrown and the copy is closed.

## Closing

`copy.close()` ends every `changes()` stream, stops what feeds them, and releases the store, so another opener can take the writer role once it returns. Calls already running finish first. Every call made after it, on the copy or any part of it, throws `MarfaError.closed`; a call racing `close()` either completes or throws that.

Tests keep keys in `Keychain.isolated()` (macOS only), a keychain file of their own outside the search list. It turns off keychain prompts for the whole process, so an app never calls it.

## The sample

`Examples/MarfaSample` is a SwiftUI app for macOS and the iOS simulator; `xcodegen generate` in that folder makes its project. `--scenario hydrate|write|drain|catch-up` runs one phase unattended and exits nonzero when a check fails. CI runs all four with the server stopped between `hydrate` and `write`.

`AGENTS.md` has the rules for working in this repository.
