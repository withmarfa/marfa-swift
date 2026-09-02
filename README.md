# MarfaSDK

The Swift SDK for the [Marfa](https://marfa.so) API — a typed data layer for structured personal data.

## Requirements

- Swift 6.2+ (Xcode 26+)
- iOS 18+, macOS 15+, visionOS 2+, watchOS 11+, tvOS 18+

## Install

In Xcode: **File → Add Package Dependencies… → `https://github.com/withmarfa/swift-sdk`**.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/withmarfa/swift-sdk", from: "15.0.0"),
]
```

## Quick start

Three client modes cover the common shapes:

```swift
import MarfaSDK

// Remote — talks to a Marfa server over HTTPS.
let client = MarfaClient(url: URL(string: "https://marfa.example.com")!, apiKey: "marfa_k1_…")

let note = try await client.items.create(
    CreateItemInput(type: "core.note", properties: ["body": .string("Hello")])
)

// Pure-local — backed by an on-device SwiftData store. No server, no API key.
let offline = try await MarfaClient.local(path: "/path/to/store.sqlite")

// Synced — writes go local first, replay to the server when reachable.
let synced = try await MarfaClient.synced(url: url, apiKey: key, storePath: "/path/to/store.sqlite")
await synced.syncEngine?.start()
```

SwiftUI-ready reactive queries are available on the pure-local and synced clients via `client.makeStore()`. See the [Swift SDK guide](https://docs.marfa.so/sdks/swift) for reactive queries, custom-type codegen, and the full API surface.

## Build and test

```bash
swift build
swift test
```

One suite talks to a real server and is skipped unless you point it at one:

```bash
MARFA_API_URL=… MARFA_API_KEY=… swift test --filter LiveSyncedClient
```

It creates items and edges and deletes them again on the way out, so give it a
space whose data is disposable. Never point it at production.

## Documentation

- Architecture, conventions, codegen workflows, and contributor guidance: [`CLAUDE.md`](./CLAUDE.md)
- Guides and API reference: <https://docs.marfa.so>
- Release notes: [`CHANGELOG.md`](./CHANGELOG.md)

## License

Apache-2.0.
