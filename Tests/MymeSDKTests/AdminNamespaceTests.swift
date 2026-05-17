import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("AdminNamespace")
struct AdminNamespaceTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func makeSummary(id: String, status: TenantStatus = .active) -> TenantSummary {
        TenantSummary(id: id, name: "tenant-\(id)", createdAt: "2026-05-01T00:00:00Z", status: status)
    }

    // MARK: - tenants

    @Test("tenants.list unwraps the data envelope into [TenantSummary]")
    func listTenants() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable { let data: [TenantSummary] }
        mock.enqueue(Envelope(data: [makeSummary(id: "t-1"), makeSummary(id: "t-2")]))

        let tenants = try await client.admin.tenants.list()

        #expect(tenants.count == 2)
        #expect(tenants[0].id == "t-1")
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/admin/tenants")
    }

    @Test("tenants.get returns the composite TenantDetail directly")
    func getTenant() async throws {
        let (client, mock) = makeClient()
        let detail = TenantDetail(
            tenant: makeSummary(id: "t-1"),
            quotas: TenantQuota(
                tenantId: "t-1",
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

        let result = try await client.admin.tenants.get(id: "t-1")

        #expect(result.tenant.id == "t-1")
        #expect(result.quotas?.itemsLimit == 1000)
        #expect(mock.calls[0].path == "/admin/tenants/t-1")
    }

    @Test("tenants.suspend POSTs /admin/tenants/{id}/suspend and returns the new summary")
    func suspendTenant() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeSummary(id: "t-1", status: .suspended))

        let summary = try await client.admin.tenants.suspend(id: "t-1")

        #expect(summary.status == .suspended)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/admin/tenants/t-1/suspend")
    }

    @Test("tenants.unsuspend POSTs /admin/tenants/{id}/unsuspend")
    func unsuspendTenant() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeSummary(id: "t-1", status: .active))

        let summary = try await client.admin.tenants.unsuspend(id: "t-1")

        #expect(summary.status == .active)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/admin/tenants/t-1/unsuspend")
    }

    @Test("tenants.metrics returns the snapshot")
    func tenantMetrics() async throws {
        let (client, mock) = makeClient()
        let metrics = TenantMetrics(
            tenantId: "t-1",
            items: TenantItemCounts(total: 100, active: 80, archived: 10, trashed: 10),
            blobs: TenantBlobCounts(count: 5, totalSize: 1024),
            recentActivity: [],
            generatedAt: "2026-05-01T00:00:00Z"
        )
        mock.enqueue(metrics)

        let result = try await client.admin.tenants.metrics(id: "t-1")

        #expect(result.items.total == 100)
        #expect(result.blobs.totalSize == 1024)
        #expect(mock.calls[0].path == "/admin/tenants/t-1/metrics")
    }

    @Test("tenants.keys unwraps the data envelope")
    func tenantKeys() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable { let data: [TenantApiKeySummary] }
        mock.enqueue(Envelope(data: [
            TenantApiKeySummary(
                id: "k-1",
                label: "test-key",
                source: "test",
                role: "member",
                isPlatform: false,
                createdAt: "2026-05-01T00:00:00Z",
                lastUsedAt: nil
            )
        ]))

        let keys = try await client.admin.tenants.keys(id: "t-1")

        #expect(keys.count == 1)
        #expect(keys[0].id == "k-1")
        #expect(mock.calls[0].path == "/admin/tenants/t-1/keys")
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
        let client = try await MymeClient.local(path: ":memory:")

        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.tenants.list()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.tenants.get(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.tenants.suspend(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.tenants.unsuspend(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.tenants.metrics(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.tenants.keys(id: "t-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.accountDeletion.purgeNow()
        }
    }
}
