import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("TokenProvider")
struct TokenProviderTests {

    @Test("StaticTokenProvider returns the wrapped API key")
    func staticProviderRoundTrip() async throws {
        let provider = StaticTokenProvider(apiKey: "key-123")
        let token = try await provider.currentToken()
        #expect(token.accessToken == "key-123")
        #expect(token.tokenType == "Bearer")
        #expect(token.refreshToken == nil)
        #expect(token.isExpired == false)
    }

    @Test("StaticTokenProvider invalidate is a no-op")
    func staticProviderInvalidate() async throws {
        let provider = StaticTokenProvider(apiKey: "key-123")
        await provider.invalidate()
        let token = try await provider.currentToken()
        #expect(token.accessToken == "key-123")
    }

    @Test("StoredTokenProvider returns cached non-expired token without network")
    func storedProviderCachedToken() async throws {
        let storage = InMemoryKeychain()
        let provider = StoredTokenProvider(
            storage: storage,
            storageKey: "myme.auth.tokens:test",
            tokenEndpoint: URL(string: "https://example.test/auth/token")!,
            clientId: "client-1"
        )
        let future = Date().addingTimeInterval(3600)
        let cached = Token(
            accessToken: "cached",
            tokenType: "Bearer",
            refreshToken: "refresh-1",
            expiresAt: future,
            scopes: ["core.note:read"]
        )
        try await provider.store(cached)

        let fetched = try await provider.currentToken()
        #expect(fetched.accessToken == "cached")
    }

    @Test("StoredTokenProvider clears storage on clear()")
    func storedProviderClear() async throws {
        let storage = InMemoryKeychain()
        let provider = StoredTokenProvider(
            storage: storage,
            storageKey: "myme.auth.tokens:test",
            tokenEndpoint: URL(string: "https://example.test/auth/token")!,
            clientId: "client-1"
        )
        let token = Token(
            accessToken: "live",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try await provider.store(token)
        #expect(try await storage.get(for: "myme.auth.tokens:test") != nil)

        try await provider.clear()
        #expect(try await storage.get(for: "myme.auth.tokens:test") == nil)
    }

    @Test("Token isExpired reflects expiry")
    func tokenExpiry() {
        let past = Token(accessToken: "x", expiresAt: Date().addingTimeInterval(-1))
        #expect(past.isExpired == true)

        let future = Token(accessToken: "x", expiresAt: Date().addingTimeInterval(3600))
        #expect(future.isExpired == false)

        let noExpiry = Token(accessToken: "x", expiresAt: nil)
        #expect(noExpiry.isExpired == false)
    }
}
