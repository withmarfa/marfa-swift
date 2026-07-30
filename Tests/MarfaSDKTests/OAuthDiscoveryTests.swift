import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Unit tests for `OAuthDiscovery`. The actor cache is process-wide and
/// keyed by issuer origin, so each test takes an origin of its own rather
/// than clearing the shared cache — see `uniqueIssuer(_:)`. A struct suite
/// is instantiated once per test, so this stored property is a fresh
/// origin every time.
@Suite("OAuthDiscovery", .timeLimit(.minutes(1)))
struct OAuthDiscoveryTests {

    private let issuer = uniqueIssuer("oauth-discovery")

    private struct DiscoveryDoc: Encodable {
        let issuer: String
        let authorization_endpoint: String?
        let token_endpoint: String?
        let revocation_endpoint: String?
        let device_authorization_endpoint: String?

        init(
            issuer: String = "https://example.test",
            authorize: String? = "https://example.test/auth/oauth2/authorize",
            token: String? = "https://example.test/auth/oauth2/token",
            revoke: String? = "https://example.test/auth/oauth2/revoke",
            deviceAuthorize: String? = "https://example.test/auth/device"
        ) {
            self.issuer = issuer
            self.authorization_endpoint = authorize
            self.token_endpoint = token
            self.revocation_endpoint = revoke
            self.device_authorization_endpoint = deviceAuthorize
        }

        /// A well-formed document for `issuer`, with every endpoint hanging off
        /// it. Discovery requires the published issuer to equal the one the
        /// caller asked for, and each test mints its own issuer, so a fixture
        /// pinned to a fixed origin is rejected before it can exercise
        /// anything else. Pass `includeToken: false` to reach the
        /// missing-field guard with the identity check already satisfied.
        init(issuer: URL, includeToken: Bool = true) {
            let origin = issuer.absoluteString
            self.init(
                issuer: origin,
                authorize: "\(origin)/auth/oauth2/authorize",
                token: includeToken ? "\(origin)/auth/oauth2/token" : nil,
                revoke: "\(origin)/auth/oauth2/revoke",
                deviceAuthorize: "\(origin)/auth/device"
            )
        }
    }

    /// Cancellation-resistant HTTP seam used to prove a pre-reset request
    /// cannot publish stale data after a replacement request has completed.
    private actor SuspendedDiscoveryHTTPClient: DeviceFlowHTTPClient {
        private let data: Data
        private let response: HTTPURLResponse
        private var started = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var responseContinuation: CheckedContinuation<(Data, URLResponse), Never>?

        init(_ document: DiscoveryDoc) throws {
            data = try JSONEncoder().encode(document)
            response = HTTPURLResponse(
                url: URL(string: "https://oauth-reset.test/.well-known/oauth-authorization-server")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            started = true
            for waiter in startedWaiters { waiter.resume() }
            startedWaiters.removeAll()
            return await withCheckedContinuation { continuation in
                responseContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { continuation in
                startedWaiters.append(continuation)
            }
        }

        func complete() {
            responseContinuation?.resume(returning: (data, response))
            responseContinuation = nil
        }
    }

    @Test("fetches and parses the well-known doc")
    func happyPath() async throws {
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(DiscoveryDoc(issuer: issuer))

        let endpoints = try await OAuthDiscovery.shared.endpoints(
            for: issuer,
            httpClient: http
        )
        let origin = issuer.absoluteString
        #expect(endpoints.token == URL(string: "\(origin)/auth/oauth2/token"))
        #expect(endpoints.authorize == URL(string: "\(origin)/auth/oauth2/authorize"))
        #expect(endpoints.revoke == URL(string: "\(origin)/auth/oauth2/revoke"))
        #expect(endpoints.deviceAuthorize == URL(string: "\(origin)/auth/device"))
        #expect(http.calls.count == 1)
        #expect(http.calls[0].url == URL(string: "\(origin)/.well-known/oauth-authorization-server"))
    }

    @Test("caches the result across sequential calls")
    func cachesAcrossCalls() async throws {
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(DiscoveryDoc(issuer: issuer))

        _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)
        _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)
        _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)

        #expect(http.calls.count == 1)
    }

    @Test("throws DiscoveryError on HTTP non-2xx")
    func httpErrorThrows() async throws {
        let http = FakeDeviceFlowHTTPClient()
        http.enqueue(data: Data("not found".utf8), status: 404)

        await #expect(throws: OAuthDiscoveryError.self) {
            _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)
        }
    }

    @Test("throws DiscoveryError on malformed JSON")
    func malformedJSONThrows() async throws {
        let http = FakeDeviceFlowHTTPClient()
        http.enqueue(data: Data("not json".utf8), status: 200)

        await #expect(throws: OAuthDiscoveryError.self) {
            _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)
        }
    }

    @Test("throws DiscoveryError when token_endpoint is missing")
    func missingFieldThrows() async throws {
        let http = FakeDeviceFlowHTTPClient()
        // The document names the requested issuer, so the identity check
        // passes and the absent endpoint is what the error has to be about.
        try http.enqueueJSON(DiscoveryDoc(issuer: issuer, includeToken: false))

        do {
            _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)
            Issue.record("expected a missing-field error")
        } catch let error as OAuthDiscoveryError {
            #expect(error.description.contains("token_endpoint"))
        }
    }

    @Test("requires the metadata issuer")
    func missingIssuerThrows() async throws {
        let http = FakeDeviceFlowHTTPClient()
        http.enqueue(
            data: Data(#"{"token_endpoint":"https://example.test/token"}"#.utf8)
        )

        await #expect(throws: OAuthDiscoveryError.self) {
            _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)
        }
    }

    @Test("rejects a metadata issuer that does not match the requested issuer")
    func issuerMismatchThrows() async throws {
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(DiscoveryDoc(issuer: "https://other.example.test"))

        do {
            _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)
            Issue.record("expected metadata issuer mismatch")
        } catch let error as OAuthDiscoveryError {
            #expect(error.description.contains("https://other.example.test"))
            #expect(error.description.contains("does not match"))
        }
    }

    @Test("rejects non-absolute and decorated requested issuers before HTTP")
    func invalidRequestedIssuerShapesThrow() async throws {
        let invalidIssuers = [
            URL(string: "space")!,
            URL(string: "https://user@example.test")!,
            URL(string: "https://example.test?space=a")!,
            URL(string: "https://example.test#space-a")!,
        ]

        for invalidIssuer in invalidIssuers {
            let discovery = OAuthDiscovery()
            let http = FakeDeviceFlowHTTPClient()
            await #expect(throws: OAuthIssuerValidationError.self) {
                _ = try await discovery.endpoints(for: invalidIssuer, httpClient: http)
            }
            #expect(http.calls.isEmpty)
        }
    }

    @Test("metadata issuer must exactly equal the requested issuer")
    func metadataIssuerRequiresExactMatch() async throws {
        let mismatchedMetadata = [
            "https://EXAMPLE.test",
            "https://example.test/",
            "https://example.test:443",
            "https://user@example.test",
            "https://example.test?space=a",
            "https://example.test#space-a",
        ]

        for metadataIssuer in mismatchedMetadata {
            let discovery = OAuthDiscovery()
            let http = FakeDeviceFlowHTTPClient()
            try http.enqueueJSON(DiscoveryDoc(issuer: metadataIssuer))
            await #expect(throws: OAuthDiscoveryError.self) {
                _ = try await discovery.endpoints(for: issuer, httpClient: http)
            }
        }
    }

    /// RFC 8414 §3.3 requires the published issuer to be identical to the
    /// issuer identifier the caller asked for. Canonicalizing the caller's
    /// side before comparing accepts a document that merely resembles the
    /// request, so this asserts the comparison stays verbatim while the
    /// canonical form still drives the well-known URL.
    @Test("comparison uses the requested spelling, URL construction the canonical one")
    func metadataComparisonUsesTheRequestedSpelling() async throws {
        let discovery = OAuthDiscovery()
        let requested = URL(string: "HTTPS://EXAMPLE.TEST/")!
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(DiscoveryDoc(issuer: "https://example.test"))

        await #expect(throws: OAuthDiscoveryError.self) {
            _ = try await discovery.endpoints(for: requested, httpClient: http)
        }
        #expect(http.calls.first?.url == URL(string: "https://example.test/.well-known/oauth-authorization-server"))

        let matching = OAuthDiscovery()
        let matchingHTTP = FakeDeviceFlowHTTPClient()
        try matchingHTTP.enqueueJSON(DiscoveryDoc(issuer: "HTTPS://EXAMPLE.TEST/"))
        _ = try await matching.endpoints(for: requested, httpClient: matchingHTTP)
        #expect(matchingHTTP.calls.first?.url == URL(string: "https://example.test/.well-known/oauth-authorization-server"))
    }

    /// A trailing slash is a common real-world issuer identifier shape.
    /// Canonicalizing it away on the request side made every such server
    /// unusable, because the published issuer could never match.
    @Test("an issuer identifier ending in a slash is usable")
    func trailingSlashIssuerIsUsable() async throws {
        let discovery = OAuthDiscovery()
        let requested = URL(string: "https://trailing-slash.test/")!
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(DiscoveryDoc(
            issuer: "https://trailing-slash.test/",
            authorize: "https://trailing-slash.test/authorize",
            token: "https://trailing-slash.test/token",
            revoke: "https://trailing-slash.test/revoke",
            deviceAuthorize: "https://trailing-slash.test/device"
        ))

        let endpoints = try await discovery.endpoints(for: requested, httpClient: http)
        #expect(endpoints.token == URL(string: "https://trailing-slash.test/token"))
        #expect(http.calls.first?.url == URL(string: "https://trailing-slash.test/.well-known/oauth-authorization-server"))
    }

    /// An issuer identifier written with an explicit default port is usable.
    /// Canonicalization lowercases and strips a trailing slash but leaves the
    /// port alone, so this shape is unaffected by which side of the comparison
    /// is canonicalized — it is pinned because a future normalization that
    /// dropped `:443` would silently merge two distinct issuers onto one cache
    /// key and one credential slot.
    @Test("an issuer identifier carrying an explicit default port is usable")
    func explicitDefaultPortIssuerIsUsable() async throws {
        let discovery = OAuthDiscovery()
        let requested = try #require(URL(string: "https://explicit-port.test:443"))
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(DiscoveryDoc(issuer: requested))

        let endpoints = try await discovery.endpoints(for: requested, httpClient: http)
        #expect(endpoints.token == URL(string: "https://explicit-port.test:443/auth/oauth2/token"))
        #expect(http.calls.first?.url == URL(
            string: "https://explicit-port.test:443/.well-known/oauth-authorization-server"
        ))
    }

    /// Two spellings of one server share a cache entry keyed on the canonical
    /// issuer, so the identity check has to be re-applied per caller rather
    /// than inherited from whoever fetched first.
    @Test("a cached document is re-checked against each caller's spelling")
    func cachedDocumentIsRecheckedPerCaller() async throws {
        let discovery = OAuthDiscovery()
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(DiscoveryDoc(issuer: issuer))

        _ = try await discovery.endpoints(for: issuer, httpClient: http)
        #expect(http.calls.count == 1)

        // Same server, different spelling: both canonicalize to one cache key,
        // so this call is answered from the entry the first one stored.
        let otherSpelling = try #require(URL(string: "\(issuer.absoluteString)/"))
        await #expect(throws: OAuthDiscoveryError.self) {
            _ = try await discovery.endpoints(for: otherSpelling, httpClient: http)
        }
        // Served from cache — the rejection is the identity check, not a refetch.
        #expect(http.calls.count == 1)
    }

    @Test("evicts the cache on rejection so a later call retries")
    func cacheEvictedOnFailure() async throws {
        let http = FakeDeviceFlowHTTPClient()
        http.enqueue(data: Data("nope".utf8), status: 500)
        try http.enqueueJSON(DiscoveryDoc(issuer: issuer))

        await #expect(throws: OAuthDiscoveryError.self) {
            _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)
        }
        // Second call should re-attempt and succeed. The proof of cache
        // eviction is that this call returns a valid endpoint set —
        // a stuck-failed cache entry would propagate the original error.
        let endpoints = try await OAuthDiscovery.shared.endpoints(
            for: issuer,
            httpClient: http
        )
        #expect(endpoints.token.absoluteString == "\(issuer.absoluteString)/auth/oauth2/token")
    }

    @Test("issuer paths have independent cache and reset scope")
    func issuerPathIsolation() async throws {
        let discovery = OAuthDiscovery()
        let issuerA = URL(string: "https://multi-issuer.test/space-a")!
        let issuerB = URL(string: "https://multi-issuer.test/space-b")!
        let httpA = FakeDeviceFlowHTTPClient()
        let httpB = FakeDeviceFlowHTTPClient()
        try httpA.enqueueJSON(DiscoveryDoc(
            issuer: "https://multi-issuer.test/space-a",
            authorize: "https://multi-issuer.test/space-a/authorize",
            token: "https://multi-issuer.test/space-a/token",
            revoke: "https://multi-issuer.test/space-a/revoke",
            deviceAuthorize: "https://multi-issuer.test/space-a/device"
        ))
        try httpB.enqueueJSON(DiscoveryDoc(
            issuer: "https://multi-issuer.test/space-b",
            authorize: "https://multi-issuer.test/space-b/authorize",
            token: "https://multi-issuer.test/space-b/token",
            revoke: "https://multi-issuer.test/space-b/revoke",
            deviceAuthorize: "https://multi-issuer.test/space-b/device"
        ))

        let endpointsA = try await discovery.endpoints(for: issuerA, httpClient: httpA)
        let endpointsB = try await discovery.endpoints(for: issuerB, httpClient: httpB)
        #expect(endpointsA.token.path == "/space-a/token")
        #expect(endpointsB.token.path == "/space-b/token")
        #expect(httpA.calls.first?.url == URL(string: "https://multi-issuer.test/.well-known/oauth-authorization-server/space-a"))
        #expect(httpB.calls.first?.url == URL(string: "https://multi-issuer.test/.well-known/oauth-authorization-server/space-b"))

        await discovery.reset(for: issuerA)
        let unusedHTTP = FakeDeviceFlowHTTPClient()
        let cachedB = try await discovery.endpoints(for: issuerB, httpClient: unusedHTTP)
        #expect(cachedB == endpointsB)
        #expect(unusedHTTP.calls.isEmpty)
    }

    @Test("reset prevents an old in-flight request from replacing fresh cache")
    func resetDuringInflightFetch() async throws {
        let discovery = OAuthDiscovery()
        let issuer = URL(string: "https://oauth-reset.test/space")!
        let staleHTTP = try SuspendedDiscoveryHTTPClient(DiscoveryDoc(
            issuer: "https://oauth-reset.test/space",
            authorize: "https://stale.test/authorize",
            token: "https://stale.test/token",
            revoke: "https://stale.test/revoke",
            deviceAuthorize: "https://stale.test/device"
        ))
        let staleRequest = Task {
            try await discovery.endpoints(for: issuer, httpClient: staleHTTP)
        }
        await staleHTTP.waitUntilStarted()

        await discovery.reset(for: issuer)
        let freshHTTP = FakeDeviceFlowHTTPClient()
        try freshHTTP.enqueueJSON(DiscoveryDoc(
            issuer: "https://oauth-reset.test/space",
            authorize: "https://fresh.test/authorize",
            token: "https://fresh.test/token",
            revoke: "https://fresh.test/revoke",
            deviceAuthorize: "https://fresh.test/device"
        ))
        let fresh = try await discovery.endpoints(for: issuer, httpClient: freshHTTP)
        #expect(fresh.token.host == "fresh.test")

        await staleHTTP.complete()
        let stale = try await staleRequest.value
        #expect(stale.token.host == "stale.test")

        let unusedHTTP = FakeDeviceFlowHTTPClient()
        let cached = try await discovery.endpoints(for: issuer, httpClient: unusedHTTP)
        #expect(cached == fresh)
        #expect(unusedHTTP.calls.isEmpty)
    }
}
