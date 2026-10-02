# marfa-swift

The Swift package `Marfa`, for iOS and macOS on Apple silicon. It embeds `MarfaCore`, the Rust engine from `withmarfa/marfa`, which holds a working copy of a slice of one Marfa server, queues writes for it with their verdicts, follows its events and keeps blobs. This package gives the core Swift types, `async` calls, change streams and typed errors.

**Nothing is published, so nothing can depend on this package by URL yet.** Its binary target is built locally and not committed.

## Building

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

`MarfaTypes`, a second product, holds the server's wire types, generated from the pinned `openapi.json`, for reading answers the working copy does not hold.

## Keys

`Server.fromEnvironment()` reads `MARFA_API_URL` and `MARFA_API_KEY`, for agents and tests, and throws when only one is set. An app keeps a person's key between launches with `Keychain.system` (`save`, `key`, `delete`), under a service and account it chooses. The working copy never writes the key to its store.

Tests keep keys in `Keychain.isolated()` (macOS only), a keychain file of their own outside the search list. It turns off keychain prompts for the whole process, so an app never calls it.

## The sample

`Examples/MarfaSample` is a SwiftUI app for macOS and the iOS simulator; `xcodegen generate` in that folder makes its project. `--scenario hydrate|write|drain|catch-up` runs one phase unattended and exits nonzero when a check fails. CI runs all four with the server stopped between `hydrate` and `write`.

`AGENTS.md` has the rules for working in this repository.
