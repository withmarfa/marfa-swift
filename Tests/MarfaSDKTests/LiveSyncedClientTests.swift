import Foundation
import Testing
@testable import MarfaSDK
import MarfaSDKTestSupport

/// The two environment variables this suite is gated on, read once.
///
/// Reading them here rather than per test keeps one answer for "is this
/// configured" across the gate and the bodies, so a suite that ran cannot then
/// find itself without a target.
private enum LiveServer {

    struct Credentials: Sendable {
        let url: URL
        let apiKey: String
    }

    static let credentials: Credentials? = {
        let environment = ProcessInfo.processInfo.environment
        guard
            let rawURL = environment["MARFA_API_URL"], !rawURL.isEmpty,
            let url = URL(string: rawURL),
            let apiKey = environment["MARFA_API_KEY"], !apiKey.isEmpty
        else {
            return nil
        }
        return Credentials(url: url, apiKey: apiKey)
    }()

    static var isConfigured: Bool { credentials != nil }
}

/// Thrown when a test body runs without credentials, which the suite's gate
/// already rules out. It exists so the bodies can bind the configuration
/// without a force unwrap.
private struct LiveServerNotConfigured: Error {}

/// Tracks what a test created and what has to be shut down, so both happen on
/// the failing path as well as the passing one.
///
/// `defer` cannot `await`, which is why this is a tracker the test hands ids to
/// rather than a block at the end of each body.
@MainActor
private final class LiveFixture {

    private var itemIds: [String] = []
    private var edgeIds: [String] = []
    private var clients: [MarfaClient] = []

    func track(item id: String) { itemIds.append(id) }
    func track(edge id: String) { edgeIds.append(id) }

    /// Registers a synced client whose engine must stop before the test
    /// returns. A running engine outlives the body otherwise and keeps writing
    /// to a store file the test is about to delete.
    func stopOnExit(_ client: MarfaClient) { clients.append(client) }

    /// Best effort throughout, and deliberately so: this runs on the failure
    /// path too, where a throw would replace the failure under investigation
    /// with one about tidying up.
    func tearDown(through client: MarfaClient) async {
        for synced in clients {
            await synced.syncEngine?.stop()
        }
        clients.removeAll()

        for id in edgeIds {
            try? await client.edges.delete(id: id)
        }
        edgeIds.removeAll()

        for id in itemIds {
            // Purge only accepts an item already in the trash, and only from a
            // key carrying `admin:purge`. The trash is the half that always
            // lands; the purge is what leaves the shared space with no rows.
            try? await client.items.delete(id: id)
            try? await client.items.purge(id: id)
        }
        itemIds.removeAll()
    }
}

/// What a synced client does against a real server.
///
/// Every test here is a reproduction: each one asserts a contract the SDK does
/// not currently keep, so a green run of this suite means the defect it names
/// is gone rather than that nothing regressed. Run it against a disposable
/// space and never against production — the tests write, and they delete what
/// they wrote through a second client on the way out.
///
/// Gated on `MARFA_API_URL` and `MARFA_API_KEY`; skipped, not passed, when
/// either is unset.
@Suite(
    "A synced client against a live server",
    // The comment is printed as the reason for the skip, so it is phrased as
    // what to do rather than as the condition that was not met.
    .enabled(
        if: LiveServer.isConfigured,
        "set MARFA_API_URL and MARFA_API_KEY to run this suite against a live server"
    )
)
@MainActor
struct LiveSyncedClientTests {

    // MARK: - Fixtures

    /// `*` on both ends, `orphan` on delete, no property constraints — so an
    /// edge between two notes is legal and can carry a property to edit.
    private static let edgeType = "references"

    private static let extensionNamespace = "live-suite"

    private func credentials() throws -> LiveServer.Credentials {
        guard let credentials = LiveServer.credentials else { throw LiveServerNotConfigured() }
        return credentials
    }

    /// A per-test marker written into every item this suite creates, so a row
    /// left behind by an interrupted run is traceable to the run that made it.
    private func runMarker() -> String {
        String(UUID().uuidString.prefix(8))
    }

    private func note(_ label: String, run: String) -> CreateItemInput {
        CreateItemInput(
            type: "core.note",
            properties: ["body": .string("live synced-client suite \(run): \(label)")]
        )
    }

    /// Newest first with a bounded page, so the items a test just created are
    /// at the front of the answer however much else the space holds.
    private func recentNotes() -> ListFilters {
        ListFilters(type: "core.note", sort: .createdAt, direction: .descending, limit: 100)
    }

    private func storePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("marfa-live-\(UUID().uuidString).sqlite")
            .path
    }

    /// SwiftData leaves `-wal` and `-shm` beside the database. A surviving
    /// journal is enough to make the next open see a store that is not empty,
    /// which is the property most of these tests rest on.
    private func removeStore(at path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func withFixture(
        cleaningUpThrough other: MarfaClient,
        _ body: (LiveFixture) async throws -> Void
    ) async throws {
        let fixture = LiveFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.tearDown(through: other)
            throw error
        }
        await fixture.tearDown(through: other)
    }

    /// Waits for the engine to report nothing left to replay.
    private func waitForDrain(
        _ engine: SyncEngine,
        timeout: Duration = .seconds(30),
        description: String
    ) async throws {
        try await waitUntil(timeout: timeout, description: description) {
            let pending = try await engine.hasPendingMutations
            return !pending
        }
    }

    // MARK: - Hydration

    @Test("a fresh store fills itself from the server after start()")
    func freshStoreHydratesAfterStart() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let first = try await other.items.create(note("hydration first", run: run))
            fixture.track(item: first.id)
            let second = try await other.items.create(note("hydration second", run: run))
            fixture.track(item: second.id)

            let device = try await MarfaClient.synced(
                url: credentials.url, apiKey: credentials.apiKey, storePath: path
            )
            fixture.stopOnExit(device)

            // `start()` and nothing else, because that is the setup the README
            // and the published SDK page show. A device that has to be told
            // separately to import is a device whose first screen is empty for
            // everyone who followed them.
            await device.syncEngine?.start()

            try await waitUntil(
                timeout: .seconds(30),
                description: "the two items the other device created to reach this device's store"
            ) {
                let page = try await device.items.list(filters: recentNotes())
                return Set(page.data.map(\.id)).isSuperset(of: [first.id, second.id])
            }
        }
    }

    // MARK: - Extensions

    @Test("an extension written here survives a metadata event from elsewhere")
    func localExtensionSurvivesAMetadataEvent() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let device = try await MarfaClient.synced(
                url: credentials.url, apiKey: credentials.apiKey, storePath: path
            )
            fixture.stopOnExit(device)
            let engine = try #require(device.syncEngine)
            await engine.start()

            let item = try await device.items.create(note("extension holder", run: run))
            fixture.track(item: item.id)
            _ = try await device.extensions.set(
                itemId: item.id,
                namespace: Self.extensionNamespace,
                data: ["state": .string("written here")]
            )
            // Both writes have to reach the server before the other device
            // touches the same row, or the tag write lands on an item that
            // does not exist yet.
            try await waitForDrain(engine, description: "the create and the extension write to replay")

            let tag = "live-\(run)"
            _ = try await other.metadata.addTags(itemId: item.id, tags: [tag])

            try await waitUntil(
                timeout: .seconds(30),
                description: "the tag added on the other device to reach this device"
            ) {
                try await device.metadata.get(itemId: item.id).tags.contains(tag)
            }

            // The event named a tag. Naming a tag is not licence to empty the
            // rest of the row, and an app that wrote an extension has no way to
            // know the next tag from anywhere will take it.
            let stored = try await device.extensions.get(
                itemId: item.id, namespace: Self.extensionNamespace
            )
            #expect(stored?["state"] == .string("written here"))
        }
    }

    @Test("an extension the server holds arrives on the initial import")
    func importCarriesServerHeldExtensions() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let item = try await other.items.create(note("server-held extension", run: run))
            fixture.track(item: item.id)
            _ = try await other.extensions.set(
                itemId: item.id,
                namespace: Self.extensionNamespace,
                data: ["state": .string("held by the server")]
            )

            let device = try await MarfaClient.synced(
                url: credentials.url, apiKey: credentials.apiKey, storePath: path
            )
            fixture.stopOnExit(device)
            let engine = try #require(device.syncEngine)

            // The import is called directly and the engine is never started:
            // whether `start()` imports at all is another test in this file,
            // and a reproduction resting on two defects at once names neither.
            _ = try await engine.performInitialSync()

            let stored = try await device.extensions.get(
                itemId: item.id, namespace: Self.extensionNamespace
            )
            #expect(stored?["state"] == .string("held by the server"))
        }
    }

    // MARK: - Edges

    @Test("an edge created here is one row here, under the id the server holds")
    func edgeCreatedHereIsASingleRow() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let device = try await MarfaClient.synced(
                url: credentials.url, apiKey: credentials.apiKey, storePath: path
            )
            fixture.stopOnExit(device)
            let engine = try #require(device.syncEngine)
            await engine.start()

            let source = try await device.items.create(note("edge source", run: run))
            fixture.track(item: source.id)
            let target = try await device.items.create(note("edge target", run: run))
            fixture.track(item: target.id)
            _ = try await device.edges.create(
                source: source.id, target: target.id, edgeType: Self.edgeType
            )

            try await waitForDrain(engine, description: "the two creates and the edge to replay")

            var serverEdgeId = ""
            try await waitUntil(
                timeout: .seconds(30),
                description: "the server to list an edge from that source"
            ) {
                let remote = try await other.edges.listFromSource(
                    sourceId: source.id, edgeType: Self.edgeType
                )
                guard let edge = remote.data.first else { return false }
                serverEdgeId = edge.id
                return true
            }
            fixture.track(edge: serverEdgeId)

            // The echo is what puts a second row in the store, so wait for it
            // to land rather than racing it: a count taken before it arrives
            // would pass for the wrong reason and stay green after a fix that
            // changed nothing.
            try await waitUntil(
                timeout: .seconds(30),
                description: "the server's edge.created echo to reach this device's store"
            ) {
                let local = try await device.edges.listFromSource(
                    sourceId: source.id, edgeType: Self.edgeType
                )
                return local.data.contains { $0.id == serverEdgeId }
            }

            let local = try await device.edges.listFromSource(
                sourceId: source.id, edgeType: Self.edgeType
            )
            #expect(
                local.data.count == 1,
                "local edge ids from that source: \(local.data.map(\.id))"
            )
            #expect(local.data.first?.id == serverEdgeId)
        }
    }

    @Test("an edge edited on another device updates on this one")
    func edgeEditedElsewhereArrivesHere() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let device = try await MarfaClient.synced(
                url: credentials.url, apiKey: credentials.apiKey, storePath: path
            )
            fixture.stopOnExit(device)
            let engine = try #require(device.syncEngine)
            await engine.start()

            let source = try await device.items.create(note("edited-edge source", run: run))
            fixture.track(item: source.id)
            let target = try await device.items.create(note("edited-edge target", run: run))
            fixture.track(item: target.id)
            _ = try await device.edges.create(
                source: source.id, target: target.id,
                edgeType: Self.edgeType, properties: ["position": .int(1)]
            )

            try await waitForDrain(engine, description: "the two creates and the edge to replay")

            var serverEdgeId = ""
            try await waitUntil(
                timeout: .seconds(30),
                description: "the server to list an edge from that source"
            ) {
                let remote = try await other.edges.listFromSource(
                    sourceId: source.id, edgeType: Self.edgeType
                )
                guard let edge = remote.data.first else { return false }
                serverEdgeId = edge.id
                return true
            }
            fixture.track(edge: serverEdgeId)

            _ = try await other.edges.update(id: serverEdgeId, properties: ["position": .int(2)])

            // Any local edge from that source will do. Pinning the assertion to
            // one id would make it depend on how many rows the edge create left
            // behind, which is a different defect with its own test above.
            try await waitUntil(
                timeout: .seconds(30),
                description: "the edge properties edited elsewhere to reach this device"
            ) {
                let local = try await device.edges.listFromSource(
                    sourceId: source.id, edgeType: Self.edgeType
                )
                return local.data.contains { $0.properties["position"] == .int(2) }
            }
        }
    }

    // MARK: - Replay

    @Test("the same create replayed twice leaves one item and an empty queue")
    func aCreateReplayedTwiceSettles() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let device = try await MarfaClient.synced(
                url: credentials.url, apiKey: credentials.apiKey, storePath: path
            )
            fixture.stopOnExit(device)
            let engine = try #require(device.syncEngine)
            let queue = try #require(device.mutationQueue)
            await engine.start()

            var input = note("replayed create", run: run)
            input.id = UUIDv7.generateString()
            let item = try await device.items.create(input)
            fixture.track(item: item.id)

            try await waitForDrain(engine, description: "the first create to replay to the server")

            // The lost-response case: the server holds the row, the client
            // never learned that, and the identical create goes back on the
            // queue. Staging it through the queue is the only way to get there
            // — the namespace would write a second local row on the way past,
            // which is not what a retry does.
            try await queue.enqueueCreateItem(input, localId: item.id)

            do {
                // Bounded short on purpose. A create that is going to settle
                // settles on the next drain, so a longer wait only lengthens
                // the report of a queue that is looping.
                try await waitUntil(
                    timeout: .seconds(15),
                    description: "the replayed create to settle and the queue to drain"
                ) {
                    try await queue.pendingCount == 0
                }
            } catch {
                // A timeout alone says the queue did not drain. What separates
                // looping from merely slow is the attempt count, so read it
                // before letting the failure through.
                let pending = try await queue.fetchAll()
                Issue.record(
                    """
                    the queue did not drain: \(pending.count) mutation(s), \
                    attempts \(pending.map(\.attemptCount)), \
                    last errors \(pending.compactMap(\.lastError))
                    """
                )
                throw error
            }

            // One item, under the id the client minted. A resolution that
            // reconciled onto a server-assigned id instead would purge the
            // local row and leave any view holding that id pointing at nothing.
            let page = try await device.items.list(filters: recentNotes())
            #expect(page.data.filter { $0.id == item.id }.count == 1)
            let remote = try await other.items.get(id: item.id)
            #expect(remote.id == item.id)
        }
    }
}
