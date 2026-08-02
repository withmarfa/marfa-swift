import Testing
import Foundation
@testable import MarfaSDK

@Suite("ClientConfiguration")
struct ClientConfigurationTests {

    // Resolved against a supplied environment rather than the process one.
    // The previous test read `ProcessInfo` directly and returned early when
    // the variables happened to be set, reporting a pass having asserted
    // nothing — and those two variables are the pair the CLI and the MCP
    // server export, so the machine most likely to run this suite is the
    // machine most likely to silence it. The success path had no test at all.

    @Test("resolves a configuration when both variables are present")
    func resolvesWhenBothPresent() {
        let config = ClientConfiguration.fromEnvironment([
            "MARFA_API_URL": "https://example.test",
            "MARFA_API_KEY": "marfa_k1_example",
        ])
        #expect(config?.url.absoluteString == "https://example.test")
        #expect(config?.apiKey == "marfa_k1_example")
    }

    @Test("returns nil when either variable is missing")
    func returnsNilWhenMissing() {
        #expect(ClientConfiguration.fromEnvironment([:]) == nil)
        #expect(
            ClientConfiguration.fromEnvironment(["MARFA_API_URL": "https://example.test"]) == nil
        )
        #expect(ClientConfiguration.fromEnvironment(["MARFA_API_KEY": "marfa_k1_example"]) == nil)
    }

    @Test("treats an empty value as missing rather than as a credential")
    func treatsEmptyAsMissing() {
        #expect(
            ClientConfiguration.fromEnvironment([
                "MARFA_API_URL": "",
                "MARFA_API_KEY": "marfa_k1_example",
            ]) == nil
        )
        #expect(
            ClientConfiguration.fromEnvironment([
                "MARFA_API_URL": "https://example.test",
                "MARFA_API_KEY": "",
            ]) == nil
        )
    }
}
