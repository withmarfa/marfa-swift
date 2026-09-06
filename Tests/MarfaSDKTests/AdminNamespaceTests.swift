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

    // MARK: - platformTypes

    /// The response is written as raw JSON rather than as `DriftedPlatformType`
    /// values. Encoding the type to produce the fixture would put its own
    /// `CodingKeys` on both sides of the assertion, so a wrong wire key —
    /// `itemCount` spelled `itemcount`, say — would round-trip through the
    /// mock and pass while failing against the server. The keys here are the
    /// ones the route sends.
    @Test("platformTypes.drift unwraps the types envelope")
    func platformTypeDrift() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(JSONValue.dictionary([
            "types": .array([
                .dictionary([
                    "id": .string("acme.deal"),
                    "item_count": .int(12),
                    "child_types": .array([.string("acme.deal.won")]),
                    "removable": .bool(false),
                ]),
                .dictionary([
                    "id": .string("acme.lead"),
                    "item_count": .int(0),
                    "child_types": .array([]),
                    "removable": .bool(true),
                ]),
            ]),
        ]))

        let drifted = try await client.admin.platformTypes.drift()

        #expect(drifted.map(\.id) == ["acme.deal", "acme.lead"])
        // The two fields a caller decides on: whether removing is allowed at
        // all, and how much still depends on the row.
        #expect(drifted[0].removable == false)
        #expect(drifted[0].itemCount == 12)
        #expect(drifted[0].childTypes == ["acme.deal.won"])
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/admin/platform-types/drift")
    }

    /// The realistic input: an identifier that came back from ``drift()``, and
    /// type identifiers are dotted by convention, so this is what the route
    /// is addressed with in practice.
    @Test("platformTypes.remove posts to the identified row")
    func platformTypeRemove() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(JSONValue.dictionary([
            "removed": .bool(true),
            "id": .string("acme.lead"),
        ]))

        try await client.admin.platformTypes.remove("acme.lead")

        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/admin/platform-types/acme.lead/remove")
        #expect(mock.calls[0].body == nil)
    }

    /// This asserted the opposite until the segment encoder existed: the id
    /// went into the path raw, so the slash opened a segment and the question
    /// mark opened a query string, and neither the path nor the verb the
    /// server saw was the one asked for.
    ///
    /// **The fix is not in `buildURL`, which is where the old note here sent
    /// the reader.** By the time a path reaches it the separators are already
    /// indistinguishable from the ones inside an id, so it can only encode a
    /// *path* — and a path encoder keeps `/` by definition. Escaping happens
    /// at the interpolation, where the segment boundary is still known.
    /// ``PathSegmentEncodingTests`` holds the general form of this.
    @Test("an id carrying a path character is escaped into one segment")
    func platformTypeRemoveEscapesTheId() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(JSONValue.dictionary([
            "removed": .bool(true),
            "id": .string("acme/deal?x=1"),
        ]))

        try await client.admin.platformTypes.remove("acme/deal?x=1")

        #expect(mock.calls[0].path == "/admin/platform-types/acme%2Fdeal%3Fx%3D1/remove")
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
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.admin.platformTypes.drift()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            try await client.admin.platformTypes.remove("acme.deal")
        }
    }
}
