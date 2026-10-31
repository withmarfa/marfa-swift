# Marfa Swift SDK

[![Latest release](https://img.shields.io/github/v/release/withmarfa/marfa-swift)](https://github.com/withmarfa/marfa-swift/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/withmarfa/marfa-swift/ci.yml?branch=main&event=push&label=CI)](https://github.com/withmarfa/marfa-swift/actions/workflows/ci.yml?query=branch%3Amain)
[![License](https://img.shields.io/github/license/withmarfa/marfa-swift)](./LICENSE)

> **Early project.** Marfa is at version 0.0.x. Things will change without notice, and nothing is stable yet.

The Swift SDK for [Marfa](https://github.com/withmarfa/marfa), a home for your personal data that you run yourself. It lets an iOS or macOS app work with a Marfa instance.

An app built on it keeps a working copy of its data on the device. The app reads from the copy with or without a connection, queues its writes until it can send them, and follows changes from the instance. The SDK gives Swift types, `async` calls and typed errors over Marfa's Rust core, which does the networking, storage and syncing.

## Where the SDK stops

- **Marfa decides what things mean**: an item's name, what a link points to, what a filter matches. The SDK passes on the core's answers, so every app agrees.
- **The SDK does what every Swift app needs**: keeping the copy in step, retrying, sorting errors, keeping keys and drawing icons.
- **Your app decides the rest**: its screens, its words and its choices.

## Add it to an app

The SDK supports iOS 27 and macOS 27, and builds with Xcode 27 on a Mac with Apple silicon.

In Xcode, choose **File** > **Add Package Dependencies**, enter `https://github.com/withmarfa/marfa-swift`, and set **Dependency Rule** to **Up to Next Major Version**. In a `Package.swift`:

```swift
.package(url: "https://github.com/withmarfa/marfa-swift", from: "<latest release>"),
// in your target's dependencies:
.product(name: "Marfa", package: "marfa-swift"),
```

Replace `<latest release>` with the version of the [latest release](https://github.com/withmarfa/marfa-swift/releases/latest). Each release carries the core already built, so your app needs no Rust toolchain. Read the [release notes](https://github.com/withmarfa/marfa-swift/releases) before you update: any release can change a call.

The SDK's enums are exhaustive. Switch over them without `@unknown default`, so a case a later release adds stops the build at each switch that must handle it.

The core is built for Apple silicon only. Set **Excluded Architectures** for **Any iOS Simulator SDK** to `x86_64` in your app target, or some simulator builds fail to link.

## Documentation

- [Swift SDK](https://docs.marfa.so/swift-sdk): the reference, with the products, the working copy, items, files, the queue, views, folders, sign-in, errors and testing.
- [Build an app with Swift](https://docs.marfa.so/build/swift-app): a tutorial that builds a SwiftUI app for iPhone and Mac.
- [Devices](https://docs.marfa.so/devices): how an app keeps a working copy and sends its changes.

The server, the core and the contract are in [withmarfa/marfa](https://github.com/withmarfa/marfa).

## Work on the SDK

Build the pinned core first. It needs the Rust toolchain and Node.js 22 or later.

```sh
scripts/core.sh
swift build
swift test
```

- `scripts/lint.sh` runs the format check.
- `Examples/MarfaSample` is a SwiftUI sample app. Run `xcodegen generate` in that folder to make its project.
- [`AGENTS.md`](./AGENTS.md) holds the rules for working in this repository.

### Icons

`Sources/MarfaIcons/LucideSymbols.swift` maps each Lucide icon to an SF Symbol, checked by hand. `scripts/icons.mjs` regenerates the icon lists and the artwork from the icon sets the pinned Marfa release names. Run it after `scripts/core.sh` whenever the table or the pin changes. The icon licenses are in [THIRD-PARTY-NOTICES.md](./THIRD-PARTY-NOTICES.md).

## License

[Apache License 2.0](./LICENSE)
