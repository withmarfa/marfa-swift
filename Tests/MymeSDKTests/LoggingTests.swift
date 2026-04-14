import Testing
import Foundation
@testable import MymeSDK

@Suite("MymeLogger")
struct LoggingTests {

    @Test("Logger uses sdk.myme subsystem")
    func subsystemIsSdkMyme() {
        #expect(MymeLogger.subsystem == "sdk.myme")
    }

    @Test("Logger can be constructed per category without throwing")
    func loggerPerCategory() {
        let transport = MymeLogger(category: "transport")
        let retry = MymeLogger(category: "retry")
        let sse = MymeLogger(category: "sse")
        let keychain = MymeLogger(category: "keychain")

        // Smoke check — emits and completes cleanly.
        transport.log.info("smoke test transport")
        retry.log.info("smoke test retry")
        sse.log.info("smoke test sse")
        keychain.log.info("smoke test keychain")
    }

    @Test("Signposter emits intervals cleanly")
    func signposterInterval() {
        let logger = MymeLogger(category: "transport")
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
