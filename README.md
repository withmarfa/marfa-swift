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

## Learn more

The documentation is at [docs.marfa.so](https://docs.marfa.so).

- [Swift SDK](https://docs.marfa.so/swift-sdk): the working copy, items, queued writes, change streams, live queries, conflicted copies and folders on a Mac.
- [Build an app with Swift](https://docs.marfa.so/guides/swift-app): a tutorial that builds a SwiftUI app for iPhone and Mac.
- [Devices](https://docs.marfa.so/devices): how an app keeps a working copy and sends its changes.
- [Write safely](https://docs.marfa.so/guides/write-safely): versions, conflicts and retries.
- [Sync a folder](https://docs.marfa.so/guides/sync-a-folder): keep a directory on your Mac in step with your notes.
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
