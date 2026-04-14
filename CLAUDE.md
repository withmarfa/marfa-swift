# MymeSDK

Swift SDK for the Myme API. Equivalent to the TypeScript `@mymehq/sdk`.

## Architecture

- **SPM package**, zero external dependencies. Built from Foundation, Security, and `os`.
- **Platforms:** iOS/macOS/visionOS/watchOS/tvOS v26. No back-deployment.
- **Swift 6** language mode with complete strict concurrency.
- **Two products:**
  - `MymeSDK` — the client library
  - `MymeSDKTestSupport` — public test scaffolding (MockTransport, InMemoryKeychain). No semver stability across SDK minor versions; for test use only.
- **`Transport` protocol** abstracts HTTP. `URLSessionTransport` is the production impl; `MockTransport` is in test-support.
- **Namespaced API**: `client.items.create()`, `client.metadata.get()`, etc.
- **`JSONValue`** enum for arbitrary JSON (Codable, Sendable, Hashable).
- **Dates as ISO 8601 strings**, not `Date` — apps parse as needed.
- **Error hierarchy:** `open class MymeError` base with `final class` subclasses (`NotFoundError`, `UnauthorizedError`, `ForbiddenError`, `ValidationError`, `ConflictError`, `NetworkError`, `ResponseDecodingError`). Pattern-match on subclasses: `catch let error as NotFoundError`.

### Transport subsystems

- **Error parsing** — internal free function `parseMymeError(data:statusCode:decoder:)` in `Errors/ErrorParsing.swift`. All non-2xx paths route through it.
- **Retry / rate limits / cancellation** — `RetryPolicy` struct (bounded exponential backoff with jitter, configurable per client) and `RateLimitState` actor (tracks `X-RateLimit-*` and `Retry-After`). Task cancellation via Swift's cooperative system; `URLError(.cancelled)` translates to `CancellationError`.
- **Observability** — `MymeLogger` wraps `os.Logger` + `OSSignposter` on the stable `"sdk.myme"` subsystem with categories `transport`, `retry`, `sse`, `keychain`. `ClientConfiguration.debugLogging` flag opts in to full-body logging at `.private` privacy.
- **SSE** — `Transport.eventStream(path:query:lastEventID:)` returns `AsyncThrowingStream<SSEEvent, Error>`. `SSEParser` is WHATWG-conformant; id is sticky across events, retry attaches to the next event that fires, blank-data blocks don't dispatch. Transport only — reconnect and cursor persistence belong to the consumer.
- **Keychain** — `SecureStorage` protocol + `KeychainStorage` actor (generic-password items under `kSecAttrService = "myme.sdk"`, optional access group for app extensions). `MymeClient.fromKeychain(service:account:url:accessGroup:)` loads a stored key; `MymeClient.saveToKeychain(...)` writes it back. `InMemoryKeychain` in test-support substitutes during unit tests because SPM test binaries run unsigned.

## Build

```bash
swift build
swift test
```

Real-Keychain tests tolerate `errSecMissingEntitlement` on unsigned SPM binaries; signed host apps exercise the real path. Integration tests against staging:

```bash
MYME_API_URL=http://100.127.105.110:8601 MYME_API_KEY=<key> swift test
```

Never run conformance or integration tests against production (`:8600`). Always staging (`:8601`).

## Conventions

- American English.
- Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`. Scope by area: `feat(sse):`, `fix(transport):`, `refactor(client):`, etc.
- Explicit `CodingKeys` for snake_case ↔ camelCase mapping. Wire types expose camelCase externally.
- All public types are `Sendable`. Mutable shared state is either actor-isolated or behind an `NSLock.withLock` critical section.
- No force unwraps. No `try!` outside of test scaffolding where the invariant is unreachable.
- Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest.
