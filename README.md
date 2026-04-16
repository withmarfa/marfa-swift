# MymeSDK

The Swift SDK for the [Myme](https://myme.so) API — a typed data layer for structured personal data.

## Requirements

- Swift 6.0+ (Xcode 16+)
- iOS 17+, macOS 14+, visionOS 1+, watchOS 10+, tvOS 17+

## Install

Add the package to your project. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mymehq/swift-sdk", from: "2.0.0"),
]
```

Or in Xcode: **File → Add Packages… → `https://github.com/mymehq/swift-sdk`**.

## Quick start

Three client modes cover the common shapes:

```swift
import MymeSDK

// 1. Remote — talks to a Myme server over HTTPS.
let client = MymeClient(url: URL(string: "https://myme.example.com")!, apiKey: "myme_k1_…")

let note = try await client.items.create(
    CreateItemInput(type: "core.note", properties: ["body": .string("Hello")])
)
print(note.id)

// 2. Pure-local — backed by an on-device SQLite store. No server, no API key.
let offline = try MymeClient.local(path: "/path/to/store.sqlite")
_ = try await offline.items.create(CreateItemInput(type: "core.note", properties: ["body": .string("Offline")]))

// 3. Synced — writes go local first, replay to the server when reachable.
let synced = try MymeClient.synced(url: url, apiKey: key, storePath: "/path/to/store.sqlite")
await synced.syncEngine?.start()
```

SwiftUI-ready reactive queries are available on the pure-local and synced clients via `client.makeStore()`:

```swift
@State private var store = try? MymeClient.local(path: dbPath).makeStore()

var body: some View {
    if let store, let notes = store.query(filters: ListFilters(type: "core.note")) {
        List(notes.items, id: \.id) { note in
            Text(note.properties["body"]?.stringValue ?? "")
        }
    }
}
```

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

- Architecture, conventions, and codegen workflow: [`CLAUDE.md`](./CLAUDE.md)
- API reference (generated from OpenAPI): <https://docs.myme.so> *(once published)*
- Myme data-model specification: [Myme Reference](https://myme.so/reference) *(once published)*

## License

MIT.
