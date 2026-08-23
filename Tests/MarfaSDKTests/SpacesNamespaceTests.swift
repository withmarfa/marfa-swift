import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("SpacesNamespace")
struct SpacesNamespaceTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    // MARK: - getConfig / setConfig

    @Test("getConfig sends GET /spaces/me/config and decodes nested enforcement")
    func getConfig() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(SpaceConfig(
            enforcement: SpaceConfig.Enforcement(
                strictMode: .init(types: ["core.note"]),
                sourceAllowlist: .init(types: ["core.task"], sources: ["sync-agent"]),
                sourceFilter: nil
            ),
            auditRetentionDays: 30,
            eventLogRetentionHours: 72,
            trashRetentionDays: 14
        ))

        let config = try await client.spaces.getConfig()

        #expect(config.enforcement?.strictMode?.types == ["core.note"])
        #expect(config.enforcement?.sourceAllowlist?.sources == ["sync-agent"])
        #expect(config.enforcement?.sourceFilter == nil)
        #expect(config.auditRetentionDays == 30)
        #expect(config.eventLogRetentionHours == 72)
        #expect(config.trashRetentionDays == 14)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/spaces/me/config")
    }

    @Test("getConfig decodes empty payload as empty config")
    func getConfigEmpty() async throws {
        let (client, mock) = makeClient()
        // The server returns `{}` when nothing is configured. A fresh
        // SpaceConfig() encodes to that exact shape (all fields nil,
        // omitted by JSONEncoder).
        mock.enqueue(SpaceConfig())

        let config = try await client.spaces.getConfig()

        #expect(config.enforcement == nil)
        #expect(config.auditRetentionDays == nil)
        #expect(config.eventLogRetentionHours == nil)
        #expect(config.trashRetentionDays == nil)
    }

    @Test("setConfig sends PUT /spaces/me/config with snake_case body")
    func setConfig() async throws {
        let (client, mock) = makeClient()
        let payload = SpaceConfig(
            enforcement: SpaceConfig.Enforcement(
                strictMode: .init(types: ["core.note", "core.task"]),
                sourceAllowlist: nil,
                sourceFilter: .init(types: ["core.bookmark"], sources: ["bulk-importer"])
            ),
            auditRetentionDays: 90,
            eventLogRetentionHours: nil,
            trashRetentionDays: 30
        )
        mock.enqueue(payload)

        let result = try await client.spaces.setConfig(payload)

        #expect(result.auditRetentionDays == 90)
        #expect(result.enforcement?.sourceFilter?.types == ["core.bookmark"])
        #expect(mock.calls[0].method == .put)
        #expect(mock.calls[0].path == "/spaces/me/config")

        let body = mock.calls[0].body!
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["audit_retention_days"] as? Int == 90)
        #expect(json["trash_retention_days"] as? Int == 30)
        // `event_log_retention_hours` is nil — should not appear in body.
        #expect(json["event_log_retention_hours"] == nil)
        let enforcement = json["enforcement"] as! [String: Any]
        let filter = enforcement["source_filter"] as! [String: Any]
        #expect(filter["sources"] as? [String] == ["bulk-importer"])
    }

    // MARK: - quotas.getOwn

    @Test("quotas.getOwn sends GET /spaces/me/quotas with no space id in path")
    func getOwnQuotas() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(SpaceQuota(
            spaceId: "space-abc",
            itemsLimit: 50_000,
            webhooksLimit: nil,
            blobsLimit: 1_000,
            storageBytesLimit: nil,
            ratePerMinuteLimit: nil,
            updatedAt: "2026-05-17T10:00:00Z"
        ))

        let quota = try await client.spaces.quotas.getOwn()

        #expect(quota.spaceId == "space-abc")
        #expect(quota.itemsLimit == 50_000)
        #expect(quota.webhooksLimit == nil)
        #expect(quota.blobsLimit == 1_000)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/spaces/me/quotas")
    }

    // MARK: - quotas.getById

    @Test("quotas.getById sends GET /spaces/{id}/quotas with id in path")
    func getByIdQuotas() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(SpaceQuota(
            spaceId: "space-xyz",
            itemsLimit: nil,
            webhooksLimit: nil,
            blobsLimit: nil,
            storageBytesLimit: nil,
            ratePerMinuteLimit: nil,
            updatedAt: nil
        ))

        let quota = try await client.spaces.quotas.getById("space-xyz")

        #expect(quota.spaceId == "space-xyz")
        // No override row — every limit nil, updated_at nil.
        #expect(quota.updatedAt == nil)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/spaces/space-xyz/quotas")
    }

    // MARK: - quotas.set

    @Test("quotas.set sends PUT /spaces/{id}/quotas with snake_case body")
    func setQuotas() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(SpaceQuota(
            spaceId: "space-xyz",
            itemsLimit: 100_000,
            webhooksLimit: 50,
            blobsLimit: nil,
            storageBytesLimit: 1_073_741_824,
            ratePerMinuteLimit: nil,
            updatedAt: "2026-05-17T12:00:00Z"
        ))

        let result = try await client.spaces.quotas.set(
            "space-xyz",
            SpaceQuotaInput(
                itemsLimit: 100_000,
                webhooksLimit: 50,
                storageBytesLimit: 1_073_741_824
            )
        )

        #expect(result.itemsLimit == 100_000)
        #expect(result.webhooksLimit == 50)
        #expect(result.storageBytesLimit == 1_073_741_824)
        #expect(mock.calls[0].method == .put)
        #expect(mock.calls[0].path == "/spaces/space-xyz/quotas")

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

    @Test("Pure-local rejects every spaces method")
    func localModeRejects() async throws {
        let client = try await MarfaClient.local(path: ":memory:")

        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.spaces.getConfig()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.spaces.setConfig(SpaceConfig())
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.spaces.quotas.getOwn()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.spaces.quotas.getById("space-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.spaces.quotas.set("space-1", SpaceQuotaInput())
        }
    }

    // MARK: - Round trip

    /// The read, change one field, write it back sequence, through the
    /// namespace rather than the model.
    ///
    /// The model's own round trip is pinned by a fixture in the wire suite,
    /// which is recursive and catches a dropped key inside `enforcement`
    /// too. This one covers the half that fixture cannot: that what the
    /// client puts on the wire for a `PUT` is what came off it for the
    /// `GET`. The other tests in this file seed the mock with a Swift value
    /// rather than wire bytes, which is tautological, and is why a model
    /// missing two fields went unnoticed here.
    @Test("a config read from the wire survives being written back")
    func configRoundTripThroughTheNamespace() async throws {
        let (client, mock) = makeClient()
        let wire = """
        {
          "enforcement": { "strict_mode": { "types": ["core.note"] } },
          "audit_retention_days": 30,
          "event_log_retention_hours": 72,
          "trash_retention_days": 14,
          "activity_retention_days": 7,
          "max_event_hop_budget": 3
        }
        """.data(using: .utf8)!

        // Queued as an opaque JSON value, so the bytes the client reads
        // never pass through `SpaceConfig` on the way in. Seeding the mock
        // with a Swift value, which is what the tests above do, cannot show
        // a field being dropped: the same model puts it in and takes it out.
        let asJSON = try JSONDecoder().decode(JSONValue.self, from: wire)
        mock.enqueue(asJSON)
        var config = try await client.spaces.getConfig()
        // The app changes the one thing it came to change.
        config.trashRetentionDays = 21

        mock.enqueue(asJSON)
        _ = try await client.spaces.setConfig(config)

        let body = try #require(mock.calls[1].body)
        let sent = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        #expect(sent["trash_retention_days"] as? Int == 21)
        // PUT is a full replacement, so a key missing here is a value erased
        // on the server, reported as a successful write.
        #expect(sent["audit_retention_days"] as? Int == 30)
        #expect(sent["event_log_retention_hours"] as? Int == 72)
        #expect(sent["activity_retention_days"] as? Int == 7)
        #expect(sent["max_event_hop_budget"] as? Int == 3)
        let enforcement = try #require(sent["enforcement"] as? [String: Any])
        let strict = try #require(enforcement["strict_mode"] as? [String: Any])
        #expect(strict["types"] as? [String] == ["core.note"])
    }
}
