import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Unit tests for `OAuthDiscovery`. The actor cache is process-wide and
/// keyed by issuer origin, so each test takes an origin of its own rather
/// than clearing the shared cache — see `uniqueIssuer(_:)`. A struct suite
/// is instantiated once per test, so this stored property is a fresh
/// origin every time.
@Suite("OAuthDiscovery")
struct OAuthDiscoveryTests {

    private let issuer = uniqueIssuer("oauth-discovery")

    private struct DiscoveryDoc: Encodable {
        let authorization_endpoint: String?
        let token_endpoint: String?
        let revocation_endpoint: String?
        let device_authorization_endpoint: String?

        init(
            authorize: String? = "https://example.test/auth/oauth2/authorize",
            token: String? = "https://example.test/auth/oauth2/token",
            revoke: String? = "https://example.test/auth/oauth2/revoke",
            deviceAuthorize: String? = "https://example.test/auth/device"
        ) {
            self.authorization_endpoint = authorize
            self.token_endpoint = token
            self.revocation_endpoint = revoke
            self.device_authorization_endpoint = deviceAuthorize
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
        try http.enqueueJSON(DiscoveryDoc())

        let endpoints = try await OAuthDiscovery.shared.endpoints(
            for: issuer,
            httpClient: http
        )
        #expect(endpoints.token == URL(string: "https://example.test/auth/oauth2/token"))
        #expect(endpoints.authorize == URL(string: "https://example.test/auth/oauth2/authorize"))
        #expect(endpoints.revoke == URL(string: "https://example.test/auth/oauth2/revoke"))
        #expect(endpoints.deviceAuthorize == URL(string: "https://example.test/auth/device"))
        #expect(http.calls.count == 1)
        #expect(http.calls[0].url?.path == "/.well-known/oauth-authorization-server")
    }

    @Test("caches the result across sequential calls")
    func cachesAcrossCalls() async throws {
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(DiscoveryDoc())

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
        try http.enqueueJSON(DiscoveryDoc(token: nil))

        await #expect(throws: OAuthDiscoveryError.self) {
            _ = try await OAuthDiscovery.shared.endpoints(for: issuer, httpClient: http)
        }
    }

    @Test("evicts the cache on rejection so a later call retries")
    func cacheEvictedOnFailure() async throws {
        let http = FakeDeviceFlowHTTPClient()
        http.enqueue(data: Data("nope".utf8), status: 500)
        try http.enqueueJSON(DiscoveryDoc())

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
        #expect(endpoints.token.absoluteString == "https://example.test/auth/oauth2/token")
    }

    @Test("issuer paths have independent cache and reset scope")
    func issuerPathIsolation() async throws {
        let discovery = OAuthDiscovery()
        let issuerA = URL(string: "https://multi-issuer.test/tenant-a")!
        let issuerB = URL(string: "https://multi-issuer.test/tenant-b")!
        let httpA = FakeDeviceFlowHTTPClient()
        let httpB = FakeDeviceFlowHTTPClient()
        try httpA.enqueueJSON(DiscoveryDoc(
            authorize: "https://multi-issuer.test/tenant-a/authorize",
            token: "https://multi-issuer.test/tenant-a/token",
            revoke: "https://multi-issuer.test/tenant-a/revoke",
            deviceAuthorize: "https://multi-issuer.test/tenant-a/device"
        ))
        try httpB.enqueueJSON(DiscoveryDoc(
            authorize: "https://multi-issuer.test/tenant-b/authorize",
            token: "https://multi-issuer.test/tenant-b/token",
            revoke: "https://multi-issuer.test/tenant-b/revoke",
            deviceAuthorize: "https://multi-issuer.test/tenant-b/device"
        ))

        let endpointsA = try await discovery.endpoints(for: issuerA, httpClient: httpA)
        let endpointsB = try await discovery.endpoints(for: issuerB, httpClient: httpB)
        #expect(endpointsA.token.path == "/tenant-a/token")
        #expect(endpointsB.token.path == "/tenant-b/token")

        await discovery.reset(for: issuerA)
        let unusedHTTP = FakeDeviceFlowHTTPClient()
        let cachedB = try await discovery.endpoints(for: issuerB, httpClient: unusedHTTP)
        #expect(cachedB == endpointsB)
        #expect(unusedHTTP.calls.isEmpty)
    }

    @Test("reset prevents an old in-flight request from replacing fresh cache")
    func resetDuringInflightFetch() async throws {
        let discovery = OAuthDiscovery()
        let issuer = URL(string: "https://oauth-reset.test/tenant")!
        let staleHTTP = try SuspendedDiscoveryHTTPClient(DiscoveryDoc(
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
