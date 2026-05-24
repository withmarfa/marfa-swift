import Testing
import Foundation
@testable import MarfaSDK

@Suite("MarfaLogger")
struct LoggingTests {

    @Test("Logger uses sdk.marfa subsystem")
    func subsystemIsSdkMarfa() {
        #expect(MarfaLogger.subsystem == "sdk.marfa")
    }

    @Test("Logger can be constructed per category without throwing")
    func loggerPerCategory() {
        let transport = MarfaLogger(category: "transport")
        let sse = MarfaLogger(category: "sse")
        let sync = MarfaLogger(category: "sync")

        // Smoke check — emits and completes cleanly.
        transport.log.info("smoke test transport")
        sse.log.info("smoke test sse")
        sync.log.info("smoke test sync")
    }

    @Test("Signposter emits intervals cleanly")
    func signposterInterval() {
        let logger = MarfaLogger(category: "transport")
        let id = logger.signposter.makeSignpostID()
        let interval = logger.signposter.beginInterval("smoke", id: id)
        logger.signposter.endInterval("smoke", interval)
    }

    @Test("debugLogging flag defaults to false")
    func debugLoggingDefaultsOff() {
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        #expect(config.debugLogging == false)
    }

    @Test("debugLogging flag can be set via initializer")
    func debugLoggingSettable() {
        let config = ClientConfiguration(
            url: URL(string: "http://test")!,
            apiKey: "k",
            debugLogging: true
        )
        #expect(config.debugLogging == true)
    }
}
