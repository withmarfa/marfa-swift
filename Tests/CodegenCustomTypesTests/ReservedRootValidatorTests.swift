import Testing
@testable import MymeCodegenCore

@Suite("Reserved namespace root validator")
struct ReservedRootValidatorTests {

    // MARK: - Reserved-root flags

    @Test("system.* flagged for non-platform authors")
    func systemFlagged() {
        let warning = Generator.reservedRootWarning(for: "system.device")
        #expect(warning != nil)
        #expect(warning?.contains("system.*") ?? false)
    }

    @Test("myme.* flagged")
    func mymeFlagged() {
        let warning = Generator.reservedRootWarning(for: "myme.something")
        #expect(warning != nil)
        #expect(warning?.contains("myme.*") ?? false)
    }

    @Test("app without app-name segment flagged")
    func appBareFlagged() {
        // app.<type> without a middle segment is malformed.
        #expect(Generator.reservedRootWarning(for: "app.foo") != nil)
    }

    @Test("user without type segment flagged")
    func userBareFlagged() {
        #expect(Generator.reservedRootWarning(for: "user") != nil)
        #expect(Generator.reservedRootWarning(for: "user.") != nil)
    }

    // MARK: - Acceptable shapes

    @Test("app.<name>.<type> accepted")
    func appNamespacedAccepted() {
        #expect(Generator.reservedRootWarning(for: "app.obsidian.daily-note") == nil)
        #expect(Generator.reservedRootWarning(for: "app.notes.thread") == nil)
    }

    @Test("user.<type> accepted")
    func userNamespacedAccepted() {
        #expect(Generator.reservedRootWarning(for: "user.recipe") == nil)
        #expect(Generator.reservedRootWarning(for: "user.kanban-card") == nil)
    }

    @Test("Publisher handles accepted")
    func publisherHandleAccepted() {
        #expect(Generator.reservedRootWarning(for: "acme.deal") == nil)
        #expect(Generator.reservedRootWarning(for: "readwise.reader") == nil)
    }
}
