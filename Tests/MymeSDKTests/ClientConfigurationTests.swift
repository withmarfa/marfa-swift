import Testing
import Foundation
@testable import MymeSDK

@Suite("ClientConfiguration")
struct ClientConfigurationTests {

    @Test("fromEnvironment returns nil when variables unset")
    func fromEnvironmentReturnsNilWhenUnset() {
        // This test relies on MYME_API_URL / MYME_API_KEY not being set in the
        // test process environment. CI runs without them by default.
        let env = ProcessInfo.processInfo.environment
        guard env["MYME_API_URL"] == nil || env["MYME_API_URL"]?.isEmpty == true,
              env["MYME_API_KEY"] == nil || env["MYME_API_KEY"]?.isEmpty == true else {
            return
        }

        #expect(ClientConfiguration.fromEnvironment() == nil)
        #expect(MymeClient.fromEnvironment() == nil)
    }
}
