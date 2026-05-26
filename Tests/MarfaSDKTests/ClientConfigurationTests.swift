import Testing
import Foundation
@testable import MarfaSDK

@Suite("ClientConfiguration")
struct ClientConfigurationTests {

    @Test("fromEnvironment returns nil when variables unset")
    func fromEnvironmentReturnsNilWhenUnset() {
        // This test relies on MARFA_API_URL / MARFA_API_KEY not being set in the
        // test process environment. CI runs without them by default.
        let env = ProcessInfo.processInfo.environment
        guard env["MARFA_API_URL"] == nil || env["MARFA_API_URL"]?.isEmpty == true,
              env["MARFA_API_KEY"] == nil || env["MARFA_API_KEY"]?.isEmpty == true else {
            return
        }

        #expect(ClientConfiguration.fromEnvironment() == nil)
        #expect(MarfaClient.fromEnvironment() == nil)
    }
}
