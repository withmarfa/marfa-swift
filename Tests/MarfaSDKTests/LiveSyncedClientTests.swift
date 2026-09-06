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
        /// Instance-admin credential, present only when `MARFA_ADMIN_API_KEY`
        /// is set. Required by the one scenario that provisions its own space;
        /// every other scenario runs without it.
        let adminApiKey: String?
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
        let admin = environment["MARFA_ADMIN_API_KEY"]
        return Credentials(
            url: url,
            apiKey: apiKey,
            adminApiKey: (admin?.isEmpty == false) ? admin : nil
        )
    }()

    static var isConfigured: Bool { credentials != nil }

    /// Hosts this suite may never provision against, whatever it was handed.
    ///
    /// **A doc comment is not a guard.** Provisioning writes a space, two
    /// credentials and an irreversible delete onto whatever instance the
    /// environment names, and the only thing standing between a stale shell
    /// and production was a sentence asking people not to. A stale
    /// `MARFA_API_URL` is exactly the input this cannot afford to trust.
    ///
    /// Deny rather than allow because the set of disposable hosts is open --
    /// a laptop, a container, a self-host on any name -- while the set that
    /// must never be touched is small, known, and the one that matters.
    private static let neverProvision: Set<String> = ["api.marfa.so"]

    /// True when this run may create and destroy a space.
    ///
    /// Three conditions, all positive: the suite is configured, an instance
    /// admin credential was supplied deliberately, and the target is not a
    /// host on the deny list.
    static var mayProvision: Bool {
        guard let c = credentials, c.adminApiKey != nil else { return false }
        guard let host = c.url.host()?.lowercased() else { return false }
        return !neverProvision.contains(host)
    }
}

/// Thrown when a test body runs without credentials, which the suite's gate
/// already rules out. It exists so the bodies can bind the configuration
/// without a force unwrap.
private struct LiveServerNotConfigured: Error {}

/// A write that had to collide and did not. Distinct from
/// ``LiveServerNotConfigured`` so a failure says what actually went wrong
/// rather than claiming the suite ran without credentials.
private struct ExpectedAConflict: Error {}

/// Wraps a transport and counts the event streams opened through it.
///
/// The engine has no way to report how many times it has subscribed, and
/// that count is the whole question below: a stream torn down and reopened
/// on a timer looks, from every other angle, exactly like one that was held.
private final class StreamCountingTransport: Transport, @unchecked Sendable {

    private let inner: any Transport
    private let lock = NSLock()
    private var opens = 0

    var streamOpens: Int { lock.withLock { opens } }

    init(wrapping inner: any Transport) { self.inner = inner }

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        try await inner.request(method: method, path: path, body: body, query: query)
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?,
        idempotencyKey: String? = nil
    ) async throws -> ConflictResult<T> {
        try await inner.requestWithConflict(
            method: method, path: path, body: body, query: query,
            idempotencyKey: idempotencyKey
        )
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        try await inner.rawRequest(
            method: method, path: path, body: body, contentType: contentType, query: query
        )
    }

    func rawUpload(
        method: HTTPMethod,
        path: String,
        body: Data,
        contentType: String?,
        query: [(String, String)]?,
        onBytesSent: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        try await inner.rawUpload(
            method: method, path: path, body: body, contentType: contentType,
            query: query, onBytesSent: onBytesSent
        )
    }

    func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        lock.withLock { opens += 1 }
        return inner.eventStream(path: path, query: query, lastEventID: lastEventID)
    }
}

/// Tracks what a test created and what has to be shut down, so both happen on
/// the failing path as well as the passing one.
///
/// `defer` cannot `await`, which is why this is a tracker the test hands ids to
/// rather than a block at the end of each body.
@MainActor
private final class LiveFixture {

    private var itemIds: [String] = []
    private var clients: [MarfaClient] = []
    private var runMarkers: [String] = []
    private var scratchKeyIds: [String] = []
    private var scratchSpaceIds: [String] = []
    private var adminClient: MarfaClient?

    func track(item id: String) { itemIds.append(id) }

    /// Registers an API key this run minted, so teardown revokes it on the
    /// failing path as well as the passing one.
    ///
    /// **Only ever an id that came back from this run's own `keys.create`.**
    /// The revoke route is space-admin gated and takes any id in the space, so
    /// a teardown that swept by label — or by anything other than what it
    /// watched being made — could revoke the credential another device, or the
    /// operator, is holding. The id is the proof of provenance and nothing
    /// else is.
    func track(scratchKey id: String) { scratchKeyIds.append(id) }

    /// Registers a space this run created, and the admin client that can
    /// remove it.
    ///
    /// **Deleting the space is what makes the keys and rows inside it
    /// somebody else's problem rather than a leak**, so it runs last and it
    /// runs on every exit path, **including a cancelled one**. Only ever an id returned by this run's own
    /// `POST /admin/spaces`: the delete route takes any id on the instance,
    /// and the two real spaces on staging are the operator's.
    func track(scratchSpace id: String, removingThrough admin: MarfaClient) {
        scratchSpaceIds.append(id)
        adminClient = admin
    }

    /// Register a run marker so teardown can find rows this test caused but
    /// never held an id for.
    ///
    /// **A keep-both conflict creates a second row as a side effect of a
    /// write**, and the id arrives in the response — so a test that fails
    /// *before* reading that response has made a row it cannot name. Tracking
    /// the id as soon as it is known closes most of that window and cannot
    /// close the part where the response never arrives, which is exactly the
    /// failure such a test is written to detect.
    ///
    /// The marker is what survives: it is written into the item's `body`, the
    /// server copies the properties onto the sibling, and the conflict
    /// scenarios deliberately collide on a different field so it is still
    /// there to be found.
    func track(marker: String) { runMarkers.append(marker) }

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

        for id in itemIds {
            // Edges are swept by asking the server what hangs off each item
            // this test created, rather than by remembering ids as they are
            // minted. A test that fails partway through has usually failed at
            // the wait that would have told it the server's edge id, and
            // `references` orphans rather than cascades, so an id-tracking
            // teardown leaks exactly the edge whose test went wrong.
            let outbound = try? await client.edges.listFromSource(sourceId: id)
            for edge in outbound?.data ?? [] {
                try? await client.edges.delete(id: edge.id)
            }
        }

        // Anything carrying a marker from this run that was never tracked by
        // id — a sibling the server made and the test never got to name.
        for marker in runMarkers {
            let listed = try? await client.items.list(
                filters: ListFilters(
                    type: "core.note", includeTrashed: true,
                    sort: .createdAt, direction: .descending, limit: 200
                )
            )
            for item in listed?.data ?? [] where !itemIds.contains(item.id) {
                guard case .string(let body)? = item.properties["body"],
                      body.contains(marker) else { continue }
                itemIds.append(item.id)
            }
        }
        runMarkers.removeAll()

        for id in itemIds {
            // Purge only accepts an item already in the trash, and the route is
            // space-admin gated. The trash is the half that always lands; the
            // purge is what leaves the shared space with no rows.
            try? await client.items.delete(id: id)
            try? await client.items.purge(id: id)
        }
        itemIds.removeAll()

        // **No key revocation here, deliberately.** Every scratch key is
        // minted inside the space below, and deleting a space takes its keys
        // with it, so a second call could only ever be redundant. The loop
        // that used to sit here was worse than redundant: it revoked through
        // the operator's credential, which cannot reach a key in another
        // space -- measured, `404` against `200` for the admin credential --
        // and `try?` hid that. It read as a belt and was not one.
        scratchKeyIds.removeAll()

        // Last of all, and through the admin credential rather than `client`,
        // which is scoped to a space it does not own. Deleting the space takes
        // its keys and its rows with it, so it is the one step here that has to
        // work.
        //
        // **Detached, because teardown may be running cancelled.**
        // swift-testing enforces `.timeLimit` by cancelling the task, so a run
        // that exhausts it arrives here with cancellation already set and every
        // request throws before it is sent -- space, keys and rows all survive.
        // That is precisely the path the control wait hands to the runner on
        // purpose, so it is the path cleanup has to survive. A detached task
        // does not inherit cancellation; awaiting its value keeps the ordering.
        if let admin = adminClient {
            let ids = scratchSpaceIds
            scratchSpaceIds.removeAll()
            await Task.detached { await LiveFixture.deleteSpaces(ids, through: admin) }.value
        } else if !scratchSpaceIds.isEmpty {
            // Unreachable while `track(scratchSpace:removingThrough:)` sets both
            // together, and recorded rather than dropped because the alternative
            // is forgetting a space with no way to name it again.
            Issue.record("spaces \(scratchSpaceIds) tracked with no admin client to remove them")
            scratchSpaceIds.removeAll()
        }
    }

    /// Deletes the spaces this run created, reporting any that survive.
    ///
    /// `nonisolated` so the detached task above runs it clear of the cancelled
    /// context it was spawned from.
    nonisolated static func deleteSpaces(_ ids: [String], through admin: MarfaClient) async {
        for id in ids {
            // **Not `try?`.** The first version swallowed the result and three
            // runs passed while leaving three spaces behind, because the route
            // requires `confirm` and answered 400 every time. A cleanup that
            // cannot fail reports success over work it never did. Recorded
            // rather than thrown, so teardown on the failing path does not mask
            // the failure that got it here.
            do {
                let result: DeletedSpace = try await admin.transport.request(
                    method: .post,
                    path: "/admin/spaces/\(id)/delete",
                    body: DeleteSpaceInput(confirm: id),
                    query: nil
                )
                if !result.deleted {
                    Issue.record("space \(id) was not deleted and is still on the server")
                }
            } catch {
                Issue.record("space \(id) survived teardown: \(error)")
            }
        }
    }
}

/// A one-slot mailbox for a value produced by a detached watcher task.
///
/// The event stream is consumed by a task the test does not await, so the
/// value has to cross an isolation boundary. An actor is the cheapest thing
/// that makes that legal without a lock the test would then have to reason
/// about.
private actor TaskBox<Value: Sendable> {
    private(set) var value: Value?
    func put(_ newValue: Value) { if value == nil { value = newValue } }
}

/// One `queueParked` announcement, as a named value rather than a tuple.
///
/// ``TaskBox`` needs a `Sendable` payload and the event carries two loose
/// values; naming them is cheaper than reasoning about tuple conformance and
/// says at the assertion which number is which.
private struct ParkAnnouncement: Sendable {
    let reason: PendingMutationBlockReason
    let count: Int
}

/// The body `POST /admin/spaces/{id}/keys` requires.
///
/// **Hand-rolled because the kit wraps no route that mints a key into another
/// space.** `AdminSpacesNamespace` reads that path with a `GET` and has no
/// `POST`, and `keys.create` is a different door: it mints into the caller's
/// own space, which is not what a scenario provisioning a space of its own can
/// use.
///
/// This comment used to say something else, and the correction is worth
/// keeping. It said the struct existed because `CreateKeyInput` carried no
/// `source` — true when written, and it made the struct look like a workaround
/// that would go away once that was fixed. It has been fixed, and this struct
/// is still needed, because the reason was never the input type. Two comments
/// had also been merged into one, so the same block described two different
/// routes.
private struct ScratchKeyInput: Codable, Sendable {
    let label: String
    let source: String
    let role: String
    let type_permissions: [String: String]
    let default_tier: String
}

/// `POST /admin/spaces` takes a name and answers the created space.
private struct CreateSpaceInput: Codable, Sendable { let name: String }
private struct CreatedSpace: Codable, Sendable { let id: String }
/// `POST /admin/spaces/{id}/delete` requires `confirm` to be the space id,
/// spelled exactly. It is the fat-finger gate on an action with no undo.
private struct DeleteSpaceInput: Codable, Sendable { let confirm: String }
private struct DeletedSpace: Codable, Sendable { let deleted: Bool }

/// What a synced client does against a real server.
///
/// **Some of these are reproductions and some are regression guards**, and the
/// difference matters when one goes red. A reproduction was written against a
/// defect and green means it is gone; a guard was written after the fix and
/// red means something came back. The doc comment on each says which. Run it against a disposable
/// space and never against production — the tests write, and they delete what
/// they wrote through a second client on the way out.
///
/// Gated on `MARFA_API_URL` and `MARFA_API_KEY`; the one scenario that
/// provisions a space of its own additionally needs `MARFA_ADMIN_API_KEY` and
/// a target that is not production, and skips without them. Skipped, not passed, when
/// either is unset.
///
/// **Not every rule belongs here, and the ones missing are missing on
/// purpose.** A live scenario earns its place when the observable depends on
/// what a real server does; where it does not, one adds runtime and a second
/// place for cleanup to be got wrong without adding evidence.
///
/// - **Rule 16 (the store's fail-safe), 17 (one writer) and 18 (store
///   identity)** are settled entirely on this side of the wire. A migration,
///   an advisory lock and an origin sidecar behave identically against a real
///   server and a mock, and each has an in-process suite that drives the cases
///   a live run could not reach — a corrupt store, a contended lock, a
///   mismatched account.
/// - **Rule 5's retry ceiling** needs a refusal that is neither permanent nor
///   environmental, repeatably. Suspending the space would *not* do it — a
///   suspended space is a `403` that `isEnvironmental` names, so it never
///   counts toward the ceiling, which is the whole point of T-1133. The
///   reachable case is a `422` for a key reused with a different request, and
///   arranging that repeatably means deliberately breaking the property rule 2
///   below exists to protect. Worth building, and larger than this change.
///   The auth half is *not* excused — it is below.
/// - **Rule 13's local validation** refuses a write *before* it is sent, so
///   the observable is the absence of a request. The registry's own tests read
///   that directly; here it would be indistinguishable from a request the
///   server happened to accept.
///
/// What that leaves is the set below: rules whose answer is the server's.
@Suite(
    "A synced client against a live server",
    // The comment is printed as the reason for the skip, so it is phrased as
    // what to do rather than as the condition that was not met.
    .enabled(
        if: LiveServer.isConfigured,
        "set MARFA_API_URL and MARFA_API_KEY to run this suite against a live server"
    ),
    // Every test here holds an SSE stream open for as long as it runs, and a
    // server caps how many viewers one space may have at once. Run in parallel
    // these tests compete for that cap, and a client refused a stream reads as
    // a device that never received an event — which is what half of them are
    // about, so the failure would look exactly like the defect.
    .serialized,
    // A backstop, not a budget. Every wait below is bounded already, and
    // those bounds are real: they are how long a round trip to a live server
    // may take, which is a delay rather than the starvation the in-process
    // suites face. This only catches a server that never answers at all.
    //
    // Eight minutes rather than one, and the number is measured rather than
    // guessed. The limit is per test function and covers fixture setup and
    // teardown, and one test here deliberately holds a stream for
    // `resourceTimeout * 1.25` — 150 seconds on the default configuration.
    // Run against staging it takes **251 seconds** end to end, so a
    // one-minute trait would have failed it by construction, and five minutes
    // would have left it 49 seconds of headroom on a quiet machine and none
    // on a busy one. Two other tests carry 150 seconds of waits between them.
    //
    // CI could not have caught any of that: this suite is gated on
    // credentials CI does not have, so it is the one place in the repository
    // where a green run proves nothing and the number has to be taken from a
    // real run.
    .timeLimit(.minutes(8))
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

    // MARK: - Time bounds

    /// The one thing that would have caught the rename, and did not exist.
    ///
    /// The kit sent `since` and `until` long after the server renamed them and
    /// began refusing both with a 400 naming the replacement. Every SDK test
    /// passed throughout, because the fixtures never look at a query string
    /// and no live test ever sent a time bound. A refusal nobody's tests reach
    /// is indistinguishable from a feature nobody uses.
    @Test("a date-bounded read reaches the server rather than being refused")
    func timeBoundedReadIsAccepted() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let created = try await other.items.create(note("time bound", run: run))
            fixture.track(item: created.id)

            // A window wide enough to hold what this run just made. Asserting
            // the row is *present* rather than that the page is non-empty:
            // this space holds other notes, so a non-empty page says nothing
            // about whether the bound admitted the item under test.
            var wide = recentNotes()
            wide.timestampAfter = "2000-01-01T00:00:00.000Z"
            wide.timestampBefore = "2100-01-01T00:00:00.000Z"
            let page = try await other.items.list(filters: wide)
            #expect(page.data.map(\.id).contains(created.id), "a bounded read lost the row it should hold")

            // Two impossible windows, one per bound, and both are needed.
            // A single upper-bound window leaves the lower bound uncovered —
            // it would pass against a server that took `timestamp_after` and
            // ignored it, or against an SDK that stopped sending it, which is
            // the exact defect this whole change is about.
            var beforeAnything = recentNotes()
            beforeAnything.timestampBefore = "2000-01-01T00:00:00.000Z"
            let noneBefore = try await other.items.list(filters: beforeAnything)
            #expect(noneBefore.data.isEmpty, "the upper bound was accepted and then ignored")

            var afterEverything = recentNotes()
            afterEverything.timestampAfter = "2100-01-01T00:00:00.000Z"
            let noneAfter = try await other.items.list(filters: afterEverything)
            #expect(noneAfter.data.isEmpty, "the lower bound was accepted and then ignored")
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
            let engine = try #require(device.syncEngine)

            // `start()` and nothing else, because that is the setup the README
            // and the published SDK page show. A device that has to be told
            // separately to import is a device whose first screen is empty for
            // everyone who followed them.
            await engine.start()

            // The longest wait in the file, and it is sized for the work a
            // hydration does rather than for the defect. An import pages items
            // 200 at a time and then pages the edges, writing each row through
            // SwiftData at tens of milliseconds a row; the demo space this runs
            // against is small only because each run empties it, and a run
            // arriving after a busy one pays for what it finds. A bound tight
            // enough to be quick here would report on how much history the
            // space happened to hold.
            try await waitUntil(
                timeout: .seconds(60),
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

    @Test("an extension written offline is on both devices once this one reconnects")
    func offlineExtensionWriteConverges() async throws {
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

            let item = try await device.items.create(note("offline extension holder", run: run))
            fixture.track(item: item.id)
            try await waitForDrain(engine, description: "the create to replay to the server")

            // Offline from here. This is the case the sync contract is actually
            // about, and it is why the test above must not be read as "the
            // local copy wins": metadata converges on the server, and what
            // rescues an offline write is that the writer replays it and the
            // server then tells everyone. Asserting that both ends hold it
            // pins the outcome without naming which half delivers it.
            await engine.stop()
            _ = try await device.extensions.set(
                itemId: item.id,
                namespace: Self.extensionNamespace,
                data: ["state": .string("written offline")]
            )

            let tag = "live-\(run)"
            _ = try await other.metadata.addTags(itemId: item.id, tags: [tag])

            await engine.start()

            // Waited for separately, and named separately, so a failure says
            // which of two different things went wrong. A queue that never
            // drains after a restart is not the same defect as a write that
            // drained and then got overwritten, and a single combined wait
            // would report them identically.
            try await waitForDrain(
                engine,
                timeout: .seconds(60),
                description: "the queued offline write to replay once the device is back"
            )

            try await waitUntil(
                timeout: .seconds(60),
                description: "the offline extension write to be readable on this device and at the server"
            ) {
                let local = try await device.extensions.get(
                    itemId: item.id, namespace: Self.extensionNamespace
                )
                let remote = try await other.extensions.get(
                    itemId: item.id, namespace: Self.extensionNamespace
                )
                return local?["state"] == .string("written offline")
                    && remote?["state"] == .string("written offline")
            }
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

            // Draining is not the same as resolving. A fix that classed this
            // 409 as permanent would empty the queue by moving the row to the
            // dropped-mutation log, which satisfies the wait above and loses
            // the write, so the wait alone would call that a pass.
            let dropped = try await queue.fetchDropped()
            #expect(
                dropped.isEmpty,
                "dropped instead of resolved: \(dropped.map { "\($0.kind) \($0.errorCode)" })"
            )
        }
    }
    // MARK: - Rule 10, conflicts are resolved by the server

    /// **Rule 10.** A `last_writer_wins` field resolves in the server's own
    /// transaction and this write's value survives.
    ///
    /// The observable is the value on the server, read back through a second
    /// client — not the value the device holds, which would agree with itself
    /// whatever happened. And it is a value rather than a timing: nothing here
    /// waits on a clock to decide the answer.
    ///
    /// **The Swift kit used to resolve this on the device and to resolve it
    /// the other way**, keeping the earlier write. So a green run here says
    /// the two implementations became one, and says which one survived.
    @Test("rule 10: a last-writer-wins conflict resolves on the server, this write winning")
    func lastWriterWinsResolvesOnTheServer() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            fixture.track(marker: run)
            let device = try await MarfaClient.synced(
                url: credentials.url, apiKey: credentials.apiKey, storePath: path
            )
            fixture.stopOnExit(device)
            let engine = try #require(device.syncEngine)

            // **The final value alone does not prove a conflict happened.** A
            // plain unconflicted update sets `title` to the same thing — so if
            // the version were dropped on the way to the replay, the server
            // would fast-merge, the drain would finish, nothing would be
            // dropped, and this test would pass without ever entering the path
            // it is named for. The merge report is what says the server
            // resolved rather than merely accepted.
            let events = engine.events
            let merges = TaskBox<ConflictAutoMergedPayload>()
            let watcher = Task {
                for await event in events {
                    if case .conflictAutoMerged(let payload) = event {
                        await merges.put(payload)
                    }
                }
            }
            defer { watcher.cancel() }

            await engine.start()

            var input = note("lww conflict", run: run)
            input.properties["title"] = .string("original")
            let item = try await device.items.create(input)
            fixture.track(item: item.id)
            try await waitForDrain(engine, description: "the create to reach the server")

            let asServerHasIt = try await other.items.get(id: item.id)

            // The other device moves the title, so this device's next write
            // names a version the server has already left behind.
            _ = try await other.items.update(
                id: item.id,
                properties: ["title": .string("from the other device")],
                options: UpdateOptions(version: asServerHasIt.version)
            )

            // Sent at the stale version deliberately. Under `.auto` the server
            // merges it rather than refusing, and `title` is last-writer-wins.
            _ = try await device.items.update(
                id: item.id,
                properties: ["title": .string("from this device")],
                options: UpdateOptions(version: asServerHasIt.version, conflict: .auto)
            )
            try await waitForDrain(engine, description: "the conflicting update to replay")

            try await waitUntil(
                timeout: .seconds(30),
                description: "the engine to report the resolution the server performed"
            ) {
                await merges.value != nil
            }
            let report = try #require(await merges.value)
            #expect(
                report.strategy["title"] == .lastWriterWins,
                "no conflict was resolved, so the surviving value proves nothing"
            )
            // Tracked before asserting: `#expect` records and continues, so a
            // sibling that should not exist would otherwise be left behind by
            // the very test that noticed it.
            if let stray = report.conflictedCopyId { fixture.track(item: stray) }
            #expect(report.conflictedCopyId == nil, "last-writer-wins spawns no sibling")

            let settled = try await other.items.get(id: item.id)
            #expect(
                settled.properties["title"] == .string("from this device"),
                "server holds \(String(describing: settled.properties["title"]))"
            )

            let queue = try #require(device.mutationQueue)
            let dropped = try await queue.fetchDropped()
            #expect(dropped.isEmpty, "dropped: \(dropped.map { "\($0.kind) \($0.errorCode)" })")
        }
    }

    /// **Rule 10, and the half no route reports.** A `keep_both_copies` field
    /// leaves the server's value on the item and puts the losing value on a
    /// sibling — and the response's `conflict_resolution` block is **the only
    /// place that sibling is ever named**, because no route says what a write
    /// created.
    ///
    /// So this asserts the id reaches the app *and* that an item exists under
    /// it. Asserting only the event would pass against a server that reported
    /// an id it never created; asserting only the count of notes would pass
    /// against a kit that dropped the id on the floor.
    @Test("rule 10: a keep-both conflict spawns a sibling and the kit is told its id")
    func keepBothSpawnsASiblingTheKitCanName() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            fixture.track(marker: run)
            let device = try await MarfaClient.synced(
                url: credentials.url, apiKey: credentials.apiKey, storePath: path
            )
            fixture.stopOnExit(device)
            let engine = try #require(device.syncEngine)

            // Subscribed before the write, because the event is the subject.
            let merges = TaskBox<ConflictAutoMergedPayload>()
            // **Hoisted out of the task deliberately.** Reading `engine.events`
            // inside it would subscribe whenever that task first ran, which is
            // a scheduling accident rather than a guarantee — and a missed
            // window is precisely the path where the wait below times out and
            // the sibling is left behind.
            let events = engine.events
            let watcher = Task {
                for await event in events {
                    if case .conflictAutoMerged(let payload) = event {
                        await merges.put(payload)
                    }
                }
            }
            defer { watcher.cancel() }

            await engine.start()

            // **Conflict on `notes`, not `body`.** Both are `keep_both_copies`
            // in `core.note`'s policy, but the run marker lives in `body` — and
            // a keep-both conflict rewrites the field it resolves, so
            // conflicting there would strip the marker from the item *and*
            // from the sibling, leaving the one row this test cannot fully
            // guarantee to clean up also untraceable to the run that made it.
            var input = note("keep-both conflict", run: run)
            // A starting value distinct from what either device writes later.
            // Seeding it with this device's eventual value would make that
            // write a no-op on the field, and a field nobody changed does not
            // conflict.
            input.properties["notes"] = .string("original notes")
            let item = try await device.items.create(input)
            fixture.track(item: item.id)
            try await waitForDrain(engine, description: "the create to reach the server")

            let asServerHasIt = try await other.items.get(id: item.id)
            _ = try await other.items.update(
                id: item.id,
                properties: ["notes": .string("the other device's notes")],
                options: UpdateOptions(version: asServerHasIt.version)
            )

            _ = try await device.items.update(
                id: item.id,
                properties: ["notes": .string("this device's notes")],
                options: UpdateOptions(version: asServerHasIt.version, conflict: .auto)
            )
            try await waitForDrain(engine, description: "the conflicting update to replay")

            try await waitUntil(
                timeout: .seconds(30),
                description: "the engine to report the resolution the server performed"
            ) {
                await merges.value != nil
            }

            // **Tracked before anything can throw.** The server creates the
            // sibling inside the write's own transaction, so it exists the
            // moment the drain returns — and the assertion most likely to fail
            // here is the one saying the id never reached the app, which is
            // exactly when the row would be left behind untracked. Guarded, so
            // tracking never becomes the throw itself.
            if let reported = await merges.value?.conflictedCopyId {
                fixture.track(item: reported)
            }

            let payload = try #require(await merges.value)
            #expect(payload.itemId == item.id)
            #expect(payload.fields.contains("notes"))
            #expect(payload.strategy["notes"] == .keepBothCopies)

            let siblingId = try #require(
                payload.conflictedCopyId,
                "no sibling id reported, so the conflicted copy is unreachable from the device"
            )

            // It exists, and it is the losing value rather than an empty row.
            let sibling = try await other.items.get(id: siblingId)
            #expect(sibling.properties["notes"] == .string("this device's notes"))

            // The tag is metadata rather than an item field, and it is what an
            // app filters on — so an untagged sibling is a sibling nobody
            // finds, whatever its id says.
            let siblingMetadata = try await other.metadata.get(itemId: siblingId)
            #expect(siblingMetadata.tags.contains(conflictedCopyTag))

            // And the original kept the server's value, which is the other
            // half of what keep-both means.
            let settled = try await other.items.get(id: item.id)
            #expect(settled.properties["notes"] == .string("the other device's notes"))
        }
    }

    // MARK: - Rules 3 and 12

    /// **Rule 3.** An update carries only the fields that changed, so a field
    /// this device holds a stale value for is not quietly written back over a
    /// newer one.
    ///
    /// **The obvious version of this test cannot fail, which is why it is
    /// written the awkward way.** A `PATCH` merges shallowly, so a key the
    /// device *omits* is never erased — a kit sending its whole property bag
    /// would omit the same key and the server would leave the other device's
    /// value standing either way. What separates the two is a key the device
    /// holds a **different** value for: send the bag and the stale value wins;
    /// send what changed and it does not.
    ///
    /// So the device is given `language: "en"` to be wrong about, and is taken
    /// offline before the other device sets `"cy"` — otherwise the inbound
    /// event would correct the local row and the whole-bag kit would send the
    /// right answer by accident.
    @Test("rule 3: an update sends what changed, leaving a field it never mentioned alone")
    func anUpdateSendsOnlyWhatChanged() async throws {
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

            var input = note("partial update", run: run)
            input.properties["title"] = .string("set by this device")
            input.properties["language"] = .string("en")
            let item = try await device.items.create(input)
            fixture.track(item: item.id)
            try await waitForDrain(engine, description: "the create to reach the server")

            // Offline before the other device writes, so the inbound event
            // cannot correct this device's copy of `language` and hand a
            // whole-bag kit the right answer by accident.
            await engine.stop()

            let asServerHasIt = try await other.items.get(id: item.id)
            _ = try await other.items.update(
                id: item.id,
                properties: ["language": .string("cy")],
                options: UpdateOptions(version: asServerHasIt.version)
            )

            // This device edits only the title while holding a stale
            // `language: "en"`. A kit sending the whole bag sends that too.
            _ = try await device.items.update(
                id: item.id,
                properties: ["title": .string("edited by this device")]
            )
            await engine.start()
            try await waitForDrain(engine, description: "the partial update to replay")

            let settled = try await other.items.get(id: item.id)
            #expect(settled.properties["title"] == .string("edited by this device"))
            #expect(
                settled.properties["language"] == .string("cy"),
                "a stale local value was written back over a newer one: \(String(describing: settled.properties["language"]))"
            )
        }
    }

    /// **Rule 12.** A deletion made elsewhere reaches a client that was
    /// connected, through `item.deleted`, rather than lingering until some
    /// later full read notices it is gone.
    ///
    /// The observable is the local store's own answer, because that is what an
    /// app renders. Asking the server would only prove the server deleted it.
    @Test("rule 12: a delete made elsewhere reaches this device")
    func aDeleteElsewhereReachesThisDevice() async throws {
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

            let item = try await device.items.create(note("deleted elsewhere", run: run))
            fixture.track(item: item.id)
            try await waitForDrain(engine, description: "the create to reach the server")

            // Present here first, or the assertion below could pass against a
            // device that never received the item at all.
            let before = try await device.items.get(id: item.id)
            #expect(before.id == item.id)

            try await other.items.delete(id: item.id)

            // **The row's state, not its absence.** A delete trashes rather
            // than removes, and the event carries the item with `state =
            // trashed`, so the row is expected to still be here — changed.
            // Waiting for it to vanish would fail on a working kit and, worse,
            // would not distinguish that from an event that never arrived.
            try await waitUntil(
                timeout: .seconds(30),
                description: "the deletion made elsewhere to reach this device's store"
            ) {
                let local = try await device.items.get(id: item.id)
                return local.state == .trashed
            }

            // Having established the event *did* arrive, the list is a second
            // question and a different rule: the same filters must select the
            // same rows here as at the server, or an app's offline view
            // silently includes what its online view excludes.
            let listedLocally = try await device.items.list(filters: recentNotes())
            let listedRemotely = try await other.items.list(filters: recentNotes())
            // **Both must exclude it, rather than merely agree.** Agreement
            // is satisfied by both pages missing the row for an unrelated
            // reason — `recentNotes()` caps at 100, and a busy space can push
            // it off both ends at once.
            #expect(
                !listedLocally.data.contains { $0.id == item.id },
                "the local list still shows a trashed row"
            )
            #expect(
                !listedRemotely.data.contains { $0.id == item.id },
                "the server list still shows a trashed row, so the control is void"
            )
        }
    }

    // MARK: - Rule 5, a refusal nobody can act on is not a classification


    /// **The auth arm driven against a credential the server really refused**,
    /// which is the one acceptance criterion on T-1315 that no in-process test
    /// can answer. `CredentialRefusedTests` proves the classification against a
    /// stubbed transport: a queued `UnauthorizedError` parks the queue. What it
    /// cannot say is whether a real server, asked by a real `URLSessionTransport`
    /// with a key that has just been revoked, produces the failure that
    /// classification is written for. A fixture is free to hand back a shape the
    /// wire never carries.
    ///
    /// **The control is the half that makes the park mean something.** A key
    /// that never worked parks identically to one that was revoked — which
    /// ``aNeverValidCredentialParksTheQueue`` covers on its own — so this one
    /// mints a scratch key, drives a write through it that the server accepts
    /// and that is then read back through a second credential inside the same
    /// space, and only then revokes it. Without that, the assertion below is
    /// satisfied by a typo.
    ///
    /// **Only the key this run minted is ever revoked**, and it is named by the
    /// id `keys.create` returned rather than by its label. See
    /// `LiveFixture.track(scratchKey:)` for why that distinction is the whole
    /// safety property.
    /// A reproduction. `keys.create` could not succeed against any server:
    /// `POST /keys` requires a `source` and ``CreateKeyInput`` carried no way
    /// to spell one, so every call was refused. Green here means the door
    /// works, and it is the only place that can say so — a mock transport
    /// accepts whatever it is handed, and the route-coverage suite reads
    /// verbs and paths rather than bodies.
    @Test(
        "keys.create mints a usable key against a real server",
        .enabled(
            if: LiveServer.mayProvision,
            "set MARFA_ADMIN_API_KEY, against a host that is not production: this scenario creates a space and deletes it"
        )
    )
    func keysCreateMintsAUsableKey() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let adminKey = try #require(credentials.adminApiKey)
        let admin = MarfaClient(url: credentials.url, apiKey: adminKey)

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let label = "keys-create-drive-\(Int(Date().timeIntervalSince1970))-\(run)"

            // A space of this run's own, so the key this scenario mints has
            // no reach into anything the operator holds and the teardown that
            // removes the space takes it whatever happens here.
            let space: CreatedSpace = try await admin.transport.request(
                method: .post,
                path: "/admin/spaces",
                body: CreateSpaceInput(name: label),
                query: nil
            )
            fixture.track(scratchSpace: space.id, removingThrough: admin)

            // The minting credential, through the admin door, because
            // `keys.create` mints into the caller's own space and the
            // operator's credential is not in this one.
            let minter: CreatedKey = try await admin.transport.request(
                method: .post,
                path: "/admin/spaces/\(space.id)/keys",
                body: ScratchKeyInput(
                    label: "\(label)-minter",
                    source: "\(label)-minter",
                    role: "space_admin",
                    type_permissions: ["*": "write"],
                    default_tier: "library"
                ),
                query: nil
            )
            fixture.track(scratchKey: minter.id)
            let inSpace = MarfaClient(url: credentials.url, apiKey: minter.key)

            // The subject.
            let made = try await inSpace.keys.create(
                CreateKeyInput(
                    label: "\(label)-minted",
                    source: "\(label)-minted",
                    role: .member,
                    typePermissions: ["core.note": .write]
                )
            )
            fixture.track(scratchKey: made.id)
            #expect(made.role == .member)
            #expect(made.source == "\(label)-minted")
            #expect(!made.key.isEmpty)

            // Usable, not merely returned. A response body proves the route
            // answered; only a request carrying the key proves it minted one.
            let minted = MarfaClient(url: credentials.url, apiKey: made.key)
            let item = try await minted.items.create(note("minted-key writes", run: run))
            fixture.track(item: item.id)
            #expect(!item.id.isEmpty)

            // And revoked through the kit as well, so both ends of the
            // namespace are driven rather than only the one under repair.
            try await inSpace.keys.revoke(id: made.id)
            await #expect(throws: (any Error).self) {
                _ = try await minted.items.create(note("after revoke", run: run))
            }
        }
    }

    @Test(
        "rule 5: a credential revoked mid-session parks the queue it was carrying",
        .enabled(
            if: LiveServer.mayProvision,
            "set MARFA_ADMIN_API_KEY, against a host that is not production: this scenario creates a space and deletes it"
        )
    )
    func aRevokedCredentialParksTheQueue() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        // The trait above already refused every run without this, so the
        // unwrap is a formality rather than the gate.
        let adminKey = try #require(credentials.adminApiKey)
        let admin = MarfaClient(url: credentials.url, apiKey: adminKey)

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let label = "t1315-drive-\(Int(Date().timeIntervalSince1970))-\(run)"

            // MARK: a space of this run's own
            //
            // **Not the shared space, and that is the whole reason this
            // scenario was rewritten.** The control below waits for a write to
            // replay, and a client's first drain waits on its initial import,
            // which pages every row in the space. Run against the operator's
            // demo space -- 3,277 items when this was written, and growing
            // every time anything else writes there -- the control raced the
            // import rather than the kit, and the bound had to be raised twice
            // before it failed anyway. An empty space makes the import trivial
            // and the wait about the thing under test.
            let space: CreatedSpace = try await admin.transport.request(
                method: .post,
                path: "/admin/spaces",
                body: CreateSpaceInput(name: label),
                query: nil
            )
            fixture.track(scratchSpace: space.id, removingThrough: admin)

            // MARK: the two credentials, both inside that space
            //
            // The device carries one and the warden reads and revokes with the
            // other. Two rather than one because the operator's credential
            // cannot see into this space at all, so the read-back that makes
            // the control mean something has to come from inside it.
            // The device writes two notes and nothing else; only the warden
            // has to revoke. `space_admin` on both was reaching for the role
            // that would certainly work rather than the one the job needs.
            func mintKey(_ suffix: String, role: String) async throws -> CreatedKey {
                try await admin.transport.request(
                    method: .post,
                    path: "/admin/spaces/\(space.id)/keys",
                    body: ScratchKeyInput(
                        label: "\(label)-\(suffix)",
                        source: "\(label)-\(suffix)",
                        role: role,
                        type_permissions: ["*": "write"],
                        default_tier: "library"
                    ),
                    query: nil
                )
            }
            let scratch = try await mintKey("device", role: "member")
            let wardenKey = try await mintKey("warden", role: "space_admin")
            // Tracked before anything else can throw. Deleting the space would
            // take them anyway; this is the belt for a run that dies before the
            // space id is usable.
            fixture.track(scratchKey: scratch.id)
            fixture.track(scratchKey: wardenKey.id)
            let warden = MarfaClient(url: credentials.url, apiKey: wardenKey.key)

            let device = try await MarfaClient.synced(
                url: credentials.url, apiKey: scratch.key, storePath: path
            )
            fixture.stopOnExit(device)
            let engine = try #require(device.syncEngine)
            let queue = try #require(device.mutationQueue)

            // Subscribed before the credential dies, because the announcement
            // is half of what the acceptance criterion asks for and it is not
            // re-emitted.
            let parks = TaskBox<ParkAnnouncement>()
            let events = engine.events
            let watcher = Task {
                for await event in events {
                    if case .queueParked(let reason, let count) = event {
                        await parks.put(ParkAnnouncement(reason: reason, count: count))
                    }
                }
            }
            defer { watcher.cancel() }

            await engine.start()

            // MARK: the control
            let control = try await device.items.create(note("control write", run: run))
            fixture.track(item: control.id)
            // **The runner owns this bound, not a number chosen here.** The
            // condition can be starved rather than merely delayed -- a drain
            // waits on the import, and the import waits on however many rows
            // the space holds -- and D61 is explicit that where that is true a
            // number in the test body reports on the machine rather than on the
            // code. The space is this run's own and holds nothing, so a wait
            // that does not settle means the kit did not replay.
            //
            // **An hour, so that raising the suite's limit cannot quietly make
            // this the operative bound.** A number merely "above the current
            // limit" becomes load-bearing the moment somebody raises that limit
            // for an unrelated reason, and nothing would say so. This one is
            // not a bound anyone will cross; it exists because the helper's
            // signature requires a `Duration`.
            try await waitForDrain(
                engine,
                timeout: .seconds(60 * 60),
                description: "the control write to replay under the scratch key"
            )

            // Read back through a second credential rather than this device's
            // store, so what is established is that the *server* accepted a
            // write from the scratch key -- which the local copy would show
            // either way. The warden is inside the same space, because the
            // operator's credential cannot see into it.
            let asServerHasIt = try await warden.items.get(id: control.id)
            #expect(
                asServerHasIt.id == control.id,
                "the scratch key never wrote anything, so a park after revoking it proves nothing"
            )

            let beforeRevocation = try await queue.counts
            #expect(
                beforeRevocation.isSettled,
                "the queue must be empty before the credential dies, or the park below could be older: \(beforeRevocation)"
            )

            // MARK: the revocation
            try await warden.keys.revoke(id: scratch.id)

            // **Synchronised on the server, not slept through.** Revocation is
            // the server's to apply and nothing here knows when it has; a write
            // made while the key still worked would drain cleanly and the wait
            // below would then time out against a kit that was behaving.
            let onTheDeadKey = MarfaClient(url: credentials.url, apiKey: scratch.key)
            try await waitUntil(
                timeout: .seconds(60),
                description: "the server to start refusing the revoked scratch key"
            ) {
                do {
                    _ = try await onTheDeadKey.items.list(filters: recentNotes())
                    return false
                } catch let error as MarfaError {
                    return error.status == 401
                }
            }

            // MARK: the write that cannot be sent
            let stranded = try await device.items.create(note("write after revocation", run: run))
            fixture.track(item: stranded.id)

            // The queue's own state, which is what an app reads, **and the
            // announcement, which is the half with no handle on it.**
            //
            // The park lands in the store and the event reaches a detached
            // watcher; those settle independently. Waiting on the store alone
            // returns while the stream may not have delivered, and reading the
            // box straight afterwards asserts about the moment before its
            // subject happens. That failed one run in five -- the queue parked
            // correctly every time and the announcement was nil -- which is
            // the flake this suite has recorded twice before under other
            // names. Both are in the condition now, so the wait is the
            // synchronisation rather than a hope.
            //
            // Bounded well past the retry ceiling: a kit that still counted a
            // `401` toward it would take five refusals and the engine's
            // back-off between them, about a minute, before blocking under the
            // wrong reason, and this has to tell that apart from parking.
            try await waitUntil(
                timeout: .seconds(120),
                description: "the queue to stop and say so, however it chooses to"
            ) {
                let counts = try await queue.counts
                let stopped = counts.blockedTotal > 0 || counts.deadLettered > 0
                let announced = await parks.value != nil
                return stopped && announced
            }

            let counts = try await queue.counts
            let row = try #require(try await queue.fetchAll().first)
            let dropped = try await queue.fetchDropped()
            let announcement = await parks.value
            let state = await engine.fullSyncState

            print(
                """
                [T-1315] control write \(control.id) accepted by the server under the scratch key
                [T-1315] after revocation: counts=\(counts)
                [T-1315] row: state=\(row.state) reason=\(String(describing: row.blockedReason)) \
                attempts=\(row.attemptCount) refusals=\(row.refusalCount) lastError=\(row.lastError ?? "none")
                [T-1315] announcement: \(String(describing: announcement))
                [T-1315] fullSyncState: \(state)
                [T-1315] dead-lettered: \(dropped.count)
                """
            )

            #expect(
                row.state == .blocked,
                "the write was left \(row.state) rather than parked, so the queue is still spinning on a dead credential"
            )
            #expect(
                row.blockedReason == .credentialRefused,
                "parked under \(String(describing: row.blockedReason)), which names the wrong remedy"
            )
            #expect(
                counts.blocked[.credentialRefused] == 1,
                "the credential class should hold the one queued write: \(counts.blocked)"
            )
            #expect(
                row.refusalCount == 0,
                "a refused credential must not spend the retry ceiling, which is for refusals of the write"
            )
            #expect(dropped.isEmpty, "a refused credential must never dead-letter an edit")
            // The recorded text, which the scenario this replaces was the only
            // thing asserting. An app shows this, so a park carrying no reason
            // or the wrong one is a park nobody can act on.
            let recorded = try #require(row.lastError, "a parked row recorded no error at all")
            #expect(
                recorded.contains("401") || recorded.lowercased().contains("unauthor"),
                "the recorded error does not name the refusal: \(recorded)"
            )

            let park = try #require(announcement, "the parking was never announced, so an app cannot show it")
            #expect(park.reason == .credentialRefused)
            #expect(park.count >= 1, "the announcement carried no rows: \(park.count)")

            if case .parked(let reason, let count) = state {
                #expect(reason == .credentialRefused)
                #expect(count >= 1)
            } else {
                Issue.record("fullSyncState reported \(state) over a parked queue")
            }

            // MARK: the credential is gone, read back rather than assumed
            //
            // Listed through the warden, which is inside the space the keys
            // live in. Listing through the operator's credential would answer
            // that space's keys instead and pass by construction, having read
            // a set the scratch key was never in.
            let remaining = try await warden.keys.list()
            #expect(
                remaining.contains(where: { $0.id == scratch.id }) == false,
                "the scratch key survived the run"
            )
            #expect(
                remaining.contains(where: { $0.id == wardenKey.id }),
                "the warden should still be live here, or this list proves nothing"
            )
        }
    }
    /// **The other half of rule 5's auth arm: a credential that never worked.**
    ///
    /// The scenario above revokes a key that had just written successfully, so
    /// what it proves is that a *live* credential going dead parks the queue.
    /// This one starts with a key the server has never seen. The two look
    /// identical from inside the queue, which is exactly why the control up
    /// there matters — and why this case is worth keeping separately rather
    /// than trusting one test to cover both.
    ///
    /// It needs no privileged credential and creates nothing on the server, so
    /// it runs wherever the suite runs.
    @Test("rule 5: a credential that never worked parks the queue too")
    func aNeverValidCredentialParksTheQueue() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)
        let path = storePath()
        defer { removeStore(at: path) }

        try await withFixture(cleaningUpThrough: other) { fixture in
            let device = try await MarfaClient.synced(
                url: credentials.url,
                apiKey: "marfa_k1_this-key-is-not-valid-and-never-was",
                storePath: path
            )
            fixture.stopOnExit(device)
            let engine = try #require(device.syncEngine)
            let queue = try #require(device.mutationQueue)
            await engine.start()

            // Never reaches the server, so there is nothing to clean up.
            let stranded = try await device.items.create(note("never valid", run: runMarker()))
            #expect(stranded.id.isEmpty == false)

            try await waitUntil(
                timeout: .seconds(60 * 60),
                description: "the queue to stop, however it chooses to"
            ) {
                let counts = try await queue.counts
                return counts.blockedTotal > 0 || counts.deadLettered > 0
            }

            let row = try #require(try await queue.fetchAll().first)
            let dropped = try await queue.fetchDropped()

            #expect(
                row.blockedReason == .credentialRefused,
                "parked under \(String(describing: row.blockedReason)) rather than the credential class"
            )
            #expect(
                row.refusalCount == 0,
                "a refused credential must not spend the retry ceiling"
            )
            #expect(dropped.isEmpty, "nothing is dropped: the write is kept for when a credential returns")
            let recorded = try #require(row.lastError, "a parked row recorded no error at all")
            #expect(
                recorded.contains("401") || recorded.lowercased().contains("unauthor"),
                "the recorded error does not name the refusal: \(recorded)"
            )
        }
    }


    // MARK: - Rule 2, a key names one request

    /// **Rule 2, and the property the conflict loop's key derivation rests
    /// on.** The server records the outcome of a keyed write *including a
    /// refusal*, and answers a repeat of that key with the stored result.
    ///
    /// The kit depends on that in a way nothing else here would catch. When a
    /// write is refused for a thinned ancestor the loop rebases onto the
    /// version the server named and retries under a key derived from it. If a
    /// replayed first attempt were **re-executed** rather than replayed, it
    /// would name a newer version each drain, the retry would derive a fresh
    /// key every time, and the guarantee would quietly be worth nothing. That
    /// was read off the specification and is measured here.
    ///
    /// The discriminator is the **version**: a re-executed conflict reports
    /// whatever the server holds now, a replayed one reports what it held the
    /// first time. Both are 409s, so status alone cannot tell them apart.
    @Test("rule 2: a repeated key replays the stored refusal rather than re-deciding it")
    func aRepeatedKeyReplaysTheStoredRefusal() async throws {
        let credentials = try credentials()
        let other = MarfaClient(url: credentials.url, apiKey: credentials.apiKey)

        try await withFixture(cleaningUpThrough: other) { fixture in
            let run = runMarker()
            let item: Item
            do { item = try await other.items.create(note("keyed refusal", run: run)) }
            catch { Issue.record("create failed: \(error)"); throw error }
            fixture.track(item: item.id)

            let transport = URLSessionTransport(
                configuration: ClientConfiguration(url: credentials.url, apiKey: credentials.apiKey)
            )
            let key = UUIDv7.generateString()
            let staleVersion = item.version
            let body = UpdateItemBody(
                properties: ["title": .string("keyed \(run)")],
                version: staleVersion
            )

            // Move the server on, so the write below names a version it has
            // left behind and is refused.
            do {
                _ = try await other.items.update(
                    id: item.id,
                    properties: ["title": .string("moved by the other device")],
                    options: UpdateOptions(version: staleVersion)
                )
            } catch { Issue.record("first move failed at v\(staleVersion): \(error)"); throw error }

            var attempt = 0
            func send() async throws -> ConflictResponse {
                attempt += 1
                let which = attempt
                let result: ConflictResult<ItemResponse>
                do {
                    result = try await transport.requestWithConflict(
                        method: .patch, path: "/items/\(item.id)", body: body,
                        query: nil, idempotencyKey: key
                    )
                } catch let error as MarfaError {
                    // Named, because this test found a real defect through
                    // this path once: the same body encoded to different bytes
                    // on the two sends, and the server refused the second as a
                    // key reused for a different request. A bare throw here
                    // reports only "MarfaError" at the test declaration, which
                    // is what made that take three runs to attribute.
                    Issue.record(
                        "keyed send \(which) failed: \(error.status) \(error.code) — \(error.message)"
                    )
                    throw error
                }
                guard case .conflict(let conflict) = result else {
                    // Its own error rather than the configuration sentinel:
                    // someone triaging this should not be told the suite had
                    // no credentials when it plainly ran.
                    throw ExpectedAConflict()
                }
                return conflict
            }

            let first = try await send()

            // Move the server again between the two attempts. A re-executed
            // request would notice; a replayed one cannot.
            do {
                _ = try await other.items.update(
                    id: item.id,
                    properties: ["title": .string("moved again")],
                    options: UpdateOptions(version: first.current.version)
                )
            } catch { Issue.record("second move failed at v\(first.current.version): \(error)"); throw error }

            let repeated = try await send()

            #expect(
                repeated.current.version == first.current.version,
                """
                the repeat was re-decided rather than replayed: first saw version \
                \(first.current.version), repeat saw \(repeated.current.version)
                """
            )

            // The control: without the key the server does re-decide, so the
            // assertion above is about the key rather than about a server that
            // simply never moves.
            let unkeyed: ConflictResult<ItemResponse> = try await transport.requestWithConflict(
                method: .patch, path: "/items/\(item.id)", body: body,
                query: nil, idempotencyKey: nil
            )
            guard case .conflict(let fresh) = unkeyed else {
                Issue.record("expected a version conflict on the unkeyed control send")
                return
            }
            #expect(
                fresh.current.version > first.current.version,
                "the server did not actually move, so the replay assertion proved nothing"
            )
        }
    }

    // MARK: - Stream lifetime

    @Test("one event stream is held open well past the ordinary resource timeout")
    func oneStreamIsHeldPastTheResourceTimeout() async throws {
        let credentials = try credentials()
        let path = storePath()
        defer { removeStore(at: path) }

        let configuration = ClientConfiguration(
            url: credentials.url, apiKey: credentials.apiKey
        )
        let transport = StreamCountingTransport(
            wrapping: URLSessionTransport(configuration: configuration)
        )
        let container = try MarfaModelContainer.make(path: path)
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let queue = await Task.detached { MutationQueue(modelContainer: container) }.value
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: ConnectionStateManager()
        )

        await engine.start()
        do {
            // The engine catches the store up before it subscribes, so the
            // first stream appears only once the initial import has landed.
            try await waitUntil(
                timeout: .seconds(120),
                description: "the engine opened its first event stream"
            ) {
                transport.streamOpens >= 1
            }
            #expect(transport.streamOpens == 1)

            // Hold past the bound that used to end a healthy stream.
            // `resourceTimeout` is exactly what a stream request no longer
            // carries, so the wait is derived from it rather than written as
            // a number, with a quarter of it again as margin.
            let hold = configuration.resourceTimeout * 1.25
            try await Task.sleep(for: .seconds(hold))

            #expect(
                transport.streamOpens == 1,
                """
                the stream was reopened \(transport.streamOpens - 1) time(s) \
                while held for \(hold)s, past the \(configuration.resourceTimeout)s \
                resource timeout an ordinary request carries
                """
            )
        } catch {
            await engine.stop()
            throw error
        }
        await engine.stop()
    }
}
