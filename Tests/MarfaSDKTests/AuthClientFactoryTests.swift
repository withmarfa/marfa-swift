import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("MarfaClient OAuth factories")
struct AuthClientFactoryTests {

    @Test("MarfaClient(url:tokenProvider:) routes via TokenProvider")
    func tokenProviderInit() async throws {
        let provider = StaticTokenProvider(apiKey: "oauth-token-xyz")
        let client = MarfaClient(
            url: URL(string: "https://example.test")!,
            tokenProvider: provider
        )
        // configuration.apiKey is empty for the OAuth path; the
        // TokenProvider holds the actual credential.
        #expect(client.configuration.apiKey == "")
    }

    @Test("ClientConfiguration(url:apiKey:) wraps key as StaticTokenProvider")
    func staticConfigDerivesProvider() async throws {
        let config = ClientConfiguration(url: URL(string: "https://example.test")!, apiKey: "k")
        let token = try await config.tokenProvider.currentToken()
        #expect(token.accessToken == "k")
    }

    @Test("ClientConfiguration(url:tokenProvider:) leaves apiKey empty")
    func providerConfigEmptyKey() async throws {
        let provider = StaticTokenProvider(apiKey: "abc")
        let config = ClientConfiguration(
            url: URL(string: "https://example.test")!,
            tokenProvider: provider
        )
        #expect(config.apiKey == "")
        let token = try await config.tokenProvider.currentToken()
        #expect(token.accessToken == "abc")
    }

    @Test("synced(url:tokenProvider:storePath:) factory builds a synced client")
    func syncedFactoryWithTokenProvider() async throws {
        let provider = StaticTokenProvider(apiKey: "synced-token")
        let client = try await MarfaClient.synced(
            url: URL(string: "https://example.test")!,
            tokenProvider: provider,
            storePath: ":memory:"
        )
        #expect(client.syncEngine != nil)
        #expect(client.configuration.apiKey == "")
    }
}
