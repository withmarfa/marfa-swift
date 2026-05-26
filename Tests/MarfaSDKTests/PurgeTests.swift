import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Tests for `ItemsNamespace.purge(id:)` — admin-scoped permanent delete.
/// Distinct from `delete(id:)` which transitions active → trashed.
@Suite("Items purge")
struct PurgeTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    @Test("Purge sends DELETE /items/:id/purge")
    func purgeSendsCorrectRequest() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.items.purge(id: "trashed-id")

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/items/trashed-id/purge")
    }

    @Test("Purge 403 (non-admin key) produces ForbiddenError")
    func purgeForbiddenError() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(ForbiddenError(message: "Admin key required"))

        await #expect(throws: ForbiddenError.self) {
            try await client.items.purge(id: "trashed-id")
        }
    }

    @Test("Purge 404 (unknown id) produces NotFoundError")
    func purgeNotFound() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(NotFoundError(message: "Item not found: unknown"))

        await #expect(throws: NotFoundError.self) {
            try await client.items.purge(id: "unknown")
        }
    }

    @Test("Purge is distinct from delete (different paths)")
    func purgeDistinctFromDelete() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())
        mock.enqueue(EmptyResponse())

        try await client.items.delete(id: "a")
        try await client.items.purge(id: "a")

        #expect(mock.calls[0].path == "/items/a")
        #expect(mock.calls[1].path == "/items/a/purge")
    }
}
