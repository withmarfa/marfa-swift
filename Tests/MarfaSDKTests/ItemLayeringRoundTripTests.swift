import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// Which layer of the store an item's fields come back from.
///
/// Two fields the wire carries and the store used to answer wrongly about, for
/// opposite reasons. The space id was dropped on the way in, so an item read
/// back locally could not say which space it came from. Extensions were never
/// on the item at all — they belong to the metadata row — and the temptation
/// is to "fix" that by adding a column, which would put one field in two
/// places and leave the two able to disagree.
@Suite("An item's space and its extensions come back from the right layer")
struct ItemLayeringRoundTripTests {

    private func serverItem(id: String, spaceId: String?) -> Item {
        Item(
            createdAt: "2026-09-03T09:00:00.000Z",
            id: id,
            properties: ["body": .string("from the server")],
            schemaVersion: 1,
            source: "api",
            spaceId: spaceId,
            state: .active,
            tier: .library,
            timestamp: "2026-09-03T09:00:00.000Z",
            type: "core.note",
            updatedAt: "2026-09-03T09:00:00.000Z",
            version: 1
        )
    }

    @Test("an item's space id survives the store")
    func spaceIdRoundTrips() async throws {
        let store = try await MarfaSDKTest.makeInMemoryLocalStore()
        let id = "019eb100-0000-7000-8000-0000000000c1"
        try await store.upsertItem(serverItem(id: id, spaceId: "space-1"))

        #expect(try await store.fetchItem(id: id).spaceId == "space-1")

        // And through the list path as well as the single read, because those
        // are two separate conversions and only one of them is exercised by
        // the line above.
        let listed = try await store.fetchItems(filters: nil).data.first { $0.id == id }
        #expect(listed?.spaceId == "space-1")
    }

    @Test("an update that does not mention the space does not erase it")
    func anAbsentSpaceIdDoesNotClearAKnownOne() async throws {
        let store = try await MarfaSDKTest.makeInMemoryLocalStore()
        let id = "019eb100-0000-7000-8000-0000000000c2"
        try await store.upsertItem(serverItem(id: id, spaceId: "space-1"))

        // Not every payload carrying an item carries its space, and an item
        // cannot move between spaces — so absent has to mean unreported. The
        // straightforward assignment would let one such event blank a value
        // the store already had, with nothing to restore it from.
        try await store.upsertItem(serverItem(id: id, spaceId: nil))
        #expect(try await store.fetchItem(id: id).spaceId == "space-1")
    }

    @Test("extensions round-trip through the metadata layer, and the item never carries them")
    func extensionsRoundTripThroughMetadata() async throws {
        let store = try await MarfaSDKTest.makeInMemoryLocalStore()
        let id = "019eb100-0000-7000-8000-0000000000c3"
        try await store.upsertItem(serverItem(id: id, spaceId: "space-1"))
        try await store.upsertMetadata(
            Metadata(
                extensions: ["reader": .dictionary(["progress": .double(0.4)])],
                itemId: id,
                tags: ["book"]
            )
        )

        let extensions = try await store.fetchExtensions(itemId: id)
        #expect(extensions["reader"]?["progress"] == .double(0.4))
        #expect(try await store.fetchMetadata(itemId: id).tags == ["book"])

        // The half that stops a column being added later. The wire type has an
        // `extensions` slot on the item and the store deliberately leaves it
        // empty: one field in two places is two fields that can disagree, and
        // the metadata row is the one the server writes through.
        #expect(try await store.fetchItem(id: id).extensions == nil)
    }
}
