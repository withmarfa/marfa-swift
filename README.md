# MymeSDK

The Swift SDK for the [Myme](https://myme.so) API — a typed data layer for structured personal data.

## Requirements

- Swift 6.2+ (Xcode 26+)
- iOS 26+, macOS 26+, visionOS 26+, watchOS 26+, tvOS 26+

## Install

In Xcode: **File → Add Package Dependencies… → `https://github.com/mymehq/swift-sdk`**.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mymehq/swift-sdk", from: "4.0.0"),
]
```

## Quick start

Three client modes cover the common shapes:

```swift
import MymeSDK

// Remote — talks to a Myme server over HTTPS.
let client = MymeClient(url: URL(string: "https://myme.example.com")!, apiKey: "myme_k1_…")

let note = try await client.items.create(
    CreateItemInput(type: "core.note", properties: ["body": .string("Hello")])
)

// Pure-local — backed by an on-device SwiftData store. No server, no API key.
let offline = try await MymeClient.local(path: "/path/to/store.sqlite")

// Synced — writes go local first, replay to the server when reachable.
let synced = try await MymeClient.synced(url: url, apiKey: key, storePath: "/path/to/store.sqlite")
await synced.syncEngine?.start()
```

SwiftUI-ready reactive queries are available on the pure-local and synced clients via `client.makeStore()`. See the [Swift SDK guide](https://docs.myme.so/sdks/swift) for reactive queries, custom-type codegen, and the full API surface.

## Build and test

```bash
swift build
swift test
```

Integration tests against a running server opt in via environment variables:

```bash
MYME_API_URL=… MYME_API_KEY=… swift test
```

## Documentation

- Architecture, conventions, codegen workflows, and contributor guidance: [`CLAUDE.md`](./CLAUDE.md)
- Guides and API reference: <https://docs.myme.so>
- Release notes: [`CHANGELOG.md`](./CHANGELOG.md)

## License

MIT.
