#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

@Suite struct MemoryKeyStoreBehavior {
    let home = URL(string: "https://marfa.example")!
    let work = URL(string: "https://work.example")!

    @Test func noKeyIsNilAndASavedKeyIsReadBack() throws {
        let store = MemoryKeyStore()
        #expect(try store.key(for: home) == nil)
        store.save("mk_a", for: home)
        #expect(try store.key(for: home) == "mk_a")
        #expect(try store.key(for: work) == nil, "a key is kept for its own address only")
    }

    @Test func savingAgainReplacesAndDeletingForgets() throws {
        let store = MemoryKeyStore([home: "mk_a"])
        store.save("mk_b", for: home)
        #expect(try store.key(for: home) == "mk_b")
        store.delete(for: home)
        #expect(try store.key(for: home) == nil)
        store.delete(for: home)
    }

    @Test func anUnreadableKeyThrowsRatherThanReadingAsNone() throws {
        let store = MemoryKeyStore([home: "mk_a", work: "mk_w"])
        store.makeUnreadable(home)
        #expect(throws: MemoryKeyStore.Unreadable.self) { try store.key(for: home) }
        #expect(try store.key(for: work) == "mk_w")
        store.save("mk_c", for: home)
        #expect(try store.key(for: home) == "mk_c", "saving a key again makes it readable")
    }

    @Test func itWorksAsAnyKeyStore() throws {
        let store: any KeyStore = MemoryKeyStore()
        try store.save("mk_a", for: home)
        #expect(try store.key(for: home) == "mk_a")
    }
}
#endif
