import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

/// Unit tests for `OAuthDiscovery`. The actor cache is process-wide, so
/// the suite is `.serialized` to prevent races between tests.
@Suite("OAuthDiscovery", .serialized)
struct OAuthDiscoveryTests {

    private let issuer = URL(string: "https://example.test")!

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

    init() async {
        await OAuthDiscovery.shared.reset()
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
}
