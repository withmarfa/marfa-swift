import Foundation
import SwiftData
import Testing
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Two metadata rows for one item must not crash the readers that index them.
///
/// `MarfaMetadataModel` is indexed on `itemId` but carries no `#Unique`,
/// because CloudKit mirroring forbids one, and writes are serialised only
/// within a single `LocalStore`. Two devices setting metadata on the same item
/// therefore leave two rows, and every reader that builds an `itemId`-keyed
/// dictionary from them traps on the duplicate rather than returning a result.
///
/// This is a crash, not a wrong answer, and it lands on the search path — so
/// on a synced device it fires on a keystroke, with the state that caused it
/// still on disk when the app relaunches.
@Suite("Duplicate metadata rows", .timeLimit(.minutes(1)))
struct DuplicateMetadataRowTests {

    /// A container holding one item and two metadata rows against its id.
    private func makeContainerWithDuplicate() async throws -> (ModelContainer, String) {
        let container = try MarfaSDKTest.makeInMemoryContainer()
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let item = try await store.createItem(
            CreateItemInput(
                type: "core.note",
                properties: ["title": .string("dupe"), "body": .string("findable")]
            )
        )
        try await store.setMetadata(itemId: item.id, input: MetadataInput(tags: ["first"]))

        // The second row is inserted directly: the store's own writer updates
        // the existing row, which is the point — one device cannot produce
        // this state, and two devices are what the schema permits.
        let context = ModelContext(container)
        let extra = MarfaMetadataModel()
        extra.itemId = item.id
        extra.tags = ["second"]
        context.insert(extra)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<MarfaMetadataModel>())
        #expect(rows.filter { $0.itemId == item.id }.count == 2)
        return (container, item.id)
    }

    @Test("fetchItemsWithMetadata survives a duplicate")
    func listSurvives() async throws {
        let (container, itemId) = try await makeContainerWithDuplicate()
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let paired = try await store.fetchItemsWithMetadata(filters: nil)
        #expect(paired.contains { $0.item.id == itemId })
    }

    @Test("searchItems survives a duplicate")
    func searchSurvives() async throws {
        let (container, itemId) = try await makeContainerWithDuplicate()
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let results = try await store.searchItems(text: "findable", filters: nil)
        #expect(results.contains { $0.item.id == itemId })
    }

    @Test("every reader resolves a duplicate to the same row as the writer")
    func readersAgreeWithWriter() async throws {
        let (container, itemId) = try await makeContainerWithDuplicate()
        let store = await Task.detached { LocalStore(modelContainer: container) }.value

        // The writer's own view. `setMetadata` and `fetchMetadata` both take
        // the first matching row, so this is the tag a detail view shows.
        try await store.setMetadata(itemId: itemId, input: MetadataInput(tags: ["authoritative"]))
        let detail = try await store.fetchMetadata(itemId: itemId)
        #expect(detail.tags == ["authoritative"])

        // A list and a search of the same item must not show something else.
        // Resolving to a different duplicate is not a crash — it is one row in
        // the list and another in the detail view, for good.
        let paired = try await store.fetchItemsWithMetadata(filters: nil)
        let listed = try #require(paired.first { $0.item.id == itemId })
        #expect(listed.metadata.tags == detail.tags)

        let results = try await store.searchItems(text: "findable", filters: nil)
        #expect(results.contains { $0.item.id == itemId })
    }

    @MainActor
    @Test("ItemsWithMetadataQuery survives a duplicate")
    func querySurvives() async throws {
        let (container, itemId) = try await makeContainerWithDuplicate()
        let query = ItemsWithMetadataQuery(container: container, filters: nil)
        defer { query.stop() }
        // The query refetches on `didSave`; the initial fetch is what this
        // covers, so wait on it settling rather than on a notification.
        try await awaitCondition(every: .milliseconds(20), description: "!query.isLoading") {
            !query.isLoading
        }
        #expect(query.error == nil)
        #expect(query.items.contains { $0.item.id == itemId })
    }
}
