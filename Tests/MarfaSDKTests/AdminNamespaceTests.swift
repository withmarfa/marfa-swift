import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("AdminNamespace")
struct AdminNamespaceTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func makeSummary(id: String, status: SpaceStatus = .active) -> SpaceSummary {
        SpaceSummary(id: id, name: "space-\(id)", createdAt: "2026-05-01T00:00:00Z", status: status)
    }

    // MARK: - spaces

    @Test("spaces.list unwraps the data envelope into [SpaceSummary]")
    func listSpaces() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable { let data: [SpaceSummary] }
        mock.enqueue(Envelope(data: [makeSummary(id: "t-1"), makeSummary(id: "t-2")]))

        let spaces = try await client.admin.spaces.list()

        #expect(spaces.count == 2)
        #expect(spaces[0].id == "t-1")
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/admin/spaces")
    }

    @Test("spaces.get returns the composite SpaceDetail directly")
    func getSpace() async throws {
        let (client, mock) = makeClient()
        let detail = SpaceDetail(
            space: makeSummary(id: "t-1"),
            quotas: SpaceQuota(
                spaceId: "t-1",
                itemsLimit: 1000,
                webhooksLimit: nil,
                blobsLimit: nil,
                storageBytesLimit: nil,
                ratePerMinuteLimit: nil,
                updatedAt: "2026-05-01T00:00:00Z"
            ),
            recentActivity: []
        )
        mock.enqueue(detail)

        let result = try await client.admin.spaces.get(id: "t-1")

        #expect(result.space.id == "t-1")
        #expect(result.quotas?.itemsLimit == 1000)
        #expect(mock.calls[0].path == "/admin/spaces/t-1")
    }

    @Test("spaces.suspend POSTs /admin/spaces/{id}/suspend and returns the new summary")
    func suspendSpace() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeSummary(id: "t-1", status: .suspended))

        let summary = try await client.admin.spaces.suspend(id: "t-1")

        #expect(summary.status == .suspended)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/admin/spaces/t-1/suspend")
    }

    @Test("spaces.unsuspend POSTs /admin/spaces/{id}/unsuspend")
    func unsuspendSpace() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeSummary(id: "t-1", status: .active))

        let summary = try await client.admin.spaces.unsuspend(id: "t-1")

        #expect(summary.status == .active)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/admin/spaces/t-1/unsuspend")
    }

    @Test("spaces.metrics returns the snapshot")
    func spaceMetrics() async throws {
        let (client, mock) = makeClient()
        let metrics = SpaceMetrics(
            spaceId: "t-1",
            items: SpaceItemCounts(total: 100, active: 80, archived: 10, trashed: 10),
            blobs: SpaceBlobCounts(count: 5, totalSize: 1024),
            recentActivity: [],
            generatedAt: "2026-05-01T00:00:00Z"
        )
        mock.enqueue(metrics)

        let result = try await client.admin.spaces.metrics(id: "t-1")

        #expect(result.items.total == 100)
        #expect(result.blobs.totalSize == 1024)
        #expect(mock.calls[0].path == "/admin/spaces/t-1/metrics")
    }

    @Test("spaces.keys unwraps the data envelope")
    func spaceKeys() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable { let data: [SpaceApiKeySummary] }
        mock.enqueue(Envelope(data: [
            SpaceApiKeySummary(
                id: "k-1",
                label: "test-key",
                source: "test",
                role: "member",
                isPlatform: false,
                createdAt: "2026-05-01T00:00:00Z",
                lastUsedAt: nil
            )
        ]))

        let keys = try await client.admin.spaces.keys(id: "t-1")

        #expect(keys.count == 1)
        #expect(keys[0].id == "k-1")
        #expect(mock.calls[0].path == "/admin/spaces/t-1/keys")
    }

    // MARK: - accountDeletion

    @Test("accountDeletion.purgeNow POSTs and returns the count")
    func purgeNow() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(PurgeNowResult(purgedCount: 3, runAt: "2026-05-01T00:00:00Z"))

        let result = try await client.admin.accountDeletion.purgeNow()

        #expect(result.purgedCount == 3)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/admin/account-deletion/purge-now")
    }

    // MARK: - Pure-local rejection

    @Test("Pure-local rejects every admin method")
    func localModeRejects() async throws {
        let client = try await MarfaClient.local(path: ":memory:")

        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.spaces.list()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.spaces.get(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.spaces.suspend(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.spaces.unsuspend(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.spaces.metrics(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.spaces.keys(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.accountDeletion.purgeNow()
        }
    }
}
