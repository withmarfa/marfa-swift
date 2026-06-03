import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("TenantsNamespace")
struct TenantsNamespaceTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    // MARK: - getConfig / setConfig

    @Test("getConfig sends GET /tenants/me/config and decodes nested enforcement")
    func getConfig() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(TenantConfig(
            enforcement: TenantConfig.Enforcement(
                strictMode: .init(types: ["core.note"]),
                sourceAllowlist: .init(types: ["core.task"], sources: ["sync-agent"]),
                sourceFilter: nil
            ),
            auditRetentionDays: 30,
            eventLogRetentionHours: 72,
            trashRetentionDays: 14
        ))

        let config = try await client.tenants.getConfig()

        #expect(config.enforcement?.strictMode?.types == ["core.note"])
        #expect(config.enforcement?.sourceAllowlist?.sources == ["sync-agent"])
        #expect(config.enforcement?.sourceFilter == nil)
        #expect(config.auditRetentionDays == 30)
        #expect(config.eventLogRetentionHours == 72)
        #expect(config.trashRetentionDays == 14)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/tenants/me/config")
    }

    @Test("getConfig decodes empty payload as empty config")
    func getConfigEmpty() async throws {
        let (client, mock) = makeClient()
        // The server returns `{}` when nothing is configured. A fresh
        // TenantConfig() encodes to that exact shape (all fields nil,
        // omitted by JSONEncoder).
        mock.enqueue(TenantConfig())

        let config = try await client.tenants.getConfig()

        #expect(config.enforcement == nil)
        #expect(config.auditRetentionDays == nil)
        #expect(config.eventLogRetentionHours == nil)
        #expect(config.trashRetentionDays == nil)
    }

    @Test("setConfig sends PUT /tenants/me/config with snake_case body")
    func setConfig() async throws {
        let (client, mock) = makeClient()
        let payload = TenantConfig(
            enforcement: TenantConfig.Enforcement(
                strictMode: .init(types: ["core.note", "core.task"]),
                sourceAllowlist: nil,
                sourceFilter: .init(types: ["core.bookmark"], sources: ["legacy-importer"])
            ),
            auditRetentionDays: 90,
            eventLogRetentionHours: nil,
            trashRetentionDays: 30
        )
        mock.enqueue(payload)

        let result = try await client.tenants.setConfig(payload)

        #expect(result.auditRetentionDays == 90)
        #expect(result.enforcement?.sourceFilter?.types == ["core.bookmark"])
        #expect(mock.calls[0].method == .put)
        #expect(mock.calls[0].path == "/tenants/me/config")

        let body = mock.calls[0].body!
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["audit_retention_days"] as? Int == 90)
        #expect(json["trash_retention_days"] as? Int == 30)
        // `event_log_retention_hours` is nil — should not appear in body.
        #expect(json["event_log_retention_hours"] == nil)
        let enforcement = json["enforcement"] as! [String: Any]
        let filter = enforcement["source_filter"] as! [String: Any]
        #expect(filter["sources"] as? [String] == ["legacy-importer"])
    }

    // MARK: - quotas.getOwn

    @Test("quotas.getOwn sends GET /tenants/me/quotas with no tenant id in path")
    func getOwnQuotas() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(TenantQuota(
            tenantId: "tenant-abc",
            itemsLimit: 50_000,
            webhooksLimit: nil,
            blobsLimit: 1_000,
            storageBytesLimit: nil,
            ratePerMinuteLimit: nil,
            updatedAt: "2026-05-17T10:00:00Z"
        ))

        let quota = try await client.tenants.quotas.getOwn()

        #expect(quota.tenantId == "tenant-abc")
        #expect(quota.itemsLimit == 50_000)
        #expect(quota.webhooksLimit == nil)
        #expect(quota.blobsLimit == 1_000)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/tenants/me/quotas")
    }

    // MARK: - quotas.getById

    @Test("quotas.getById sends GET /tenants/{id}/quotas with id in path")
    func getByIdQuotas() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(TenantQuota(
            tenantId: "tenant-xyz",
            itemsLimit: nil,
            webhooksLimit: nil,
            blobsLimit: nil,
            storageBytesLimit: nil,
            ratePerMinuteLimit: nil,
            updatedAt: nil
        ))

        let quota = try await client.tenants.quotas.getById("tenant-xyz")

        #expect(quota.tenantId == "tenant-xyz")
        // No override row — every limit nil, updated_at nil.
        #expect(quota.updatedAt == nil)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/tenants/tenant-xyz/quotas")
    }

    // MARK: - quotas.set

    @Test("quotas.set sends PUT /tenants/{id}/quotas with snake_case body")
    func setQuotas() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(TenantQuota(
            tenantId: "tenant-xyz",
            itemsLimit: 100_000,
            webhooksLimit: 50,
            blobsLimit: nil,
            storageBytesLimit: 1_073_741_824,
            ratePerMinuteLimit: nil,
            updatedAt: "2026-05-17T12:00:00Z"
        ))

        let result = try await client.tenants.quotas.set(
            "tenant-xyz",
            TenantQuotaInput(
                itemsLimit: 100_000,
                webhooksLimit: 50,
                storageBytesLimit: 1_073_741_824
            )
        )

        #expect(result.itemsLimit == 100_000)
        #expect(result.webhooksLimit == 50)
        #expect(result.storageBytesLimit == 1_073_741_824)
        #expect(mock.calls[0].method == .put)
        #expect(mock.calls[0].path == "/tenants/tenant-xyz/quotas")

        let body = mock.calls[0].body!
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["items_limit"] as? Int == 100_000)
        #expect(json["webhooks_limit"] as? Int == 50)
        #expect(json["storage_bytes_limit"] as? Int == 1_073_741_824)
        // Omitted fields stay absent.
        #expect(json["blobs_limit"] == nil)
        #expect(json["rate_per_minute_limit"] == nil)
    }

    // MARK: - Pure-local rejection

    @Test("Pure-local rejects every tenants method")
    func localModeRejects() async throws {
        let client = try await MarfaClient.local(path: ":memory:")

        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.tenants.getConfig()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.tenants.setConfig(TenantConfig())
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.tenants.quotas.getOwn()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.tenants.quotas.getById("tenant-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.tenants.quotas.set("tenant-1", TenantQuotaInput())
        }
    }
}
