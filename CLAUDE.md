# MymeSDK

Swift SDK for the Myme API. Equivalent to the TypeScript `@mymehq/sdk`.

## Architecture

- **SPM package**, zero external dependencies
- **Swift 6** strict concurrency (Sendable, async/await)
- **URLSession-based** HTTP transport with bearer token auth
- **`Transport` protocol** for testability (mock in tests)
- **Namespaced API**: `client.items.create()`, `client.metadata.get()`, etc.
- **`JSONValue`** enum for arbitrary JSON (Codable, Sendable, Hashable)
- **Dates as ISO 8601 strings**, not `Date` — apps parse as needed

## Build

```bash
swift build
swift test
```

Integration tests require staging server access:
```bash
MYME_API_URL=http://100.127.105.110:8601 MYME_API_KEY=<key> swift test
```

## Conventions

- American English
- Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`
- Explicit `CodingKeys` for snake_case ↔ camelCase mapping
- All public types are `Sendable`
- Error hierarchy uses `final class` (enables `catch let error as NotFoundError`)
