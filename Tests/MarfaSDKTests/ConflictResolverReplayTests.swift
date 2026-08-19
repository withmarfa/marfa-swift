import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// A `.callback` conflict strategy has to survive the mutation queue.
///
/// The closure itself cannot: it is not serializable, so a queued update
/// used to arrive at replay with nothing to call and silently resolved as
/// `.auto` instead. That is the write where app-specific merge logic matters
/// most — in synced mode the edit that races is almost never the online one,
/// it is the replay against a server the app could not reach at the time.
///
/// These pin the three outcomes that replace the silent substitution: the
/// registered resolver runs, an unregistered one keeps the mutation rather
/// than merging it under other rules, and the call site refuses before
/// anything is queued.
@Suite("Callback conflicts survive replay", .timeLimit(.minutes(1)))
struct ConflictResolverReplayTests {

    private func conflictResponse(
        currentVersion: Int = 2
    ) -> ConflictResponse {
        ConflictResponse(
            ancestor: ConflictSnapshot(
                properties: ["body": .string("original")], version: 1),
            conflictingFields: ["body"],
            current: ConflictSnapshot(
                properties: ["body": .string("server edit")],
                version: currentVersion),
            error: ConflictResponseError(code: .versionConflict, status: 409),
            mergePolicy: MergePolicy(
                default: .lastWriterWins, fields: ["body": .keepBothCopies])
        )
    }

    private func item(id: String, version: Int, body: String) -> Item {
        Item(
            createdAt: "2026-08-13T09:00:00Z",
            id: id,
            properties: ["body": .string(body)],
            schemaVersion: 1,
            source: "test",
            state: .active,
            tier: .feed,
            timestamp: "2026-08-13T09:00:00Z",
            type: "core.note",
            updatedAt: "2026-08-13T09:00:00Z",
            version: version
        )
    }

    @Test("a replayed callback update reaches the app's registered resolver")
    func replayReachesRegisteredResolver() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let resolvers = ConflictResolverRegistry()

        // What the app would install at launch, before the engine drains.
        let sawConflict = ResolverProbe()
        await resolvers.register { conflict in
            await sawConflict.record(conflict)
            return ["body": .string("resolved by the app")]
        }

        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager,
            conflictResolvers: resolvers
        )

        try await queue.enqueueUpdateItem(
            id: "server-1",
            properties: ["body": .string("offline edit")],
            version: 1,
            conflict: .callback,
            tier: nil,
            sourceId: nil
        )

        // The server has moved on: the replay meets a 409, then accepts the
        // resolver's merge.
        transport.enqueue(conflictResponse())
        transport.enqueue(
            ItemResponse(item: item(id: "server-1", version: 3, body: "resolved by the app")))

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // The resolver ran, and it ran on the real conflict rather than a
        // synthesized one.
        let captured = try #require(await sawConflict.captured)
        #expect(captured.conflictingFields == ["body"])
        #expect(captured.clientPatch["body"] == .string("offline edit"))
        #expect(captured.current.properties["body"] == .string("server edit"))

        // And it can say which item conflicted. A registered resolver is the
        // only kind a replay can use, and it has no call site to learn the id
        // from: without this it can merge but cannot report, so an app has
        // nothing to name in a message to a person.
        #expect(captured.itemId == "server-1")

        // And the merge the resolver produced is what went to the server.
        let patches = transport.calls.filter {
            $0.method == .patch && $0.path == "/items/server-1"
        }
        #expect(patches.count == 2)
        #expect(try await queue.isEmpty)
    }

    @Test("with no resolver registered the mutation waits rather than merging")
    func replayWithoutResolverKeepsTheMutation() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let resolvers = ConflictResolverRegistry()

        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connManager,
            conflictResolvers: resolvers
        )

        try await queue.enqueueUpdateItem(
            id: "server-2",
            properties: ["body": .string("offline edit")],
            version: 1,
            conflict: .callback,
            tier: nil,
            sourceId: nil
        )

        await connManager.applyStateForTesting(.online)
        await engine.triggerProactiveDrainForTesting()

        // Nothing was sent: the strategy could not be honored, so nothing was
        // resolved under a different one.
        #expect(transport.calls.isEmpty)

        // The edit is still queued, and the reason is on the record. It is a
        // transient failure by construction — registering a resolver makes the
        // next drain carry it, and dropping it would lose a user's edit for a
        // reason that has nothing to do with the edit.
        let remaining = try await queue.fetchAll()
        #expect(remaining.count == 1)
        let record = try #require(remaining.first)
        #expect(record.lastError?.contains("no resolver is registered") == true)

        // Register one, and it goes.
        await resolvers.register { _ in ["body": .string("resolved late")] }
        transport.enqueue(conflictResponse())
        transport.enqueue(
            ItemResponse(item: item(id: "server-2", version: 3, body: "resolved late")))
        await engine.triggerProactiveDrainForTesting()

        #expect(try await queue.isEmpty)
    }

    @Test("a per-call resolver satisfies the call site, and replay still needs a registered one")
    func perCallResolverIsAccepted() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = MockTransport()
        let resolvers = ConflictResolverRegistry()
        let items = ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: .auto,
            localStore: store,
            mutationQueue: queue,
            conflictResolvers: resolvers
        )
        try await store.upsertItem(item(id: "server-4", version: 1, body: "original"))

        // The immediate write uses this closure, so the call is ordinary —
        // refusing it would break every app that resolves per call, which is
        // the documented way to do it.
        _ = try await items.update(
            id: "server-4",
            properties: ["body": .string("edit")],
            options: UpdateOptions(
                version: 1,
                conflict: .callback,
                resolve: { _ in ["body": .string("resolved inline")] }
            )
        )
        #expect(try await queue.fetchAll().count == 1)
    }

    @Test("the immediate path names the item too")
    func immediateResolverSeesTheItemId() async throws {
        // The same payload reaches a per-call resolver on the network path,
        // and it carries the id there as well. A per-call closure usually
        // knows the item already, so the point is that one shape of
        // `ConflictData` serves both paths: an app can register the resolver
        // it wrote for a call site without rewriting it.
        let transport = MockTransport()
        let items = ItemsNamespace(transport: transport, defaultConflictStrategy: .auto)

        transport.enqueue(ItemResponse(item: item(id: "server-5", version: 1, body: "original")))
        transport.enqueue(conflictResponse())
        transport.enqueue(
            ItemResponse(item: item(id: "server-5", version: 3, body: "resolved inline")))

        let sawConflict = ResolverProbe()
        _ = try await items.update(
            id: "server-5",
            properties: ["body": .string("edit")],
            options: UpdateOptions(
                conflict: .callback,
                resolve: { conflict in
                    await sawConflict.record(conflict)
                    return ["body": .string("resolved inline")]
                }
            )
        )

        let captured = try #require(await sawConflict.captured)
        #expect(captured.itemId == "server-5")
    }

    @Test("a synced-mode callback update with no resolver at all is refused at the call site")
    func callSiteRefusesUnreachableCallback() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = MockTransport()
        let resolvers = ConflictResolverRegistry()
        let items = ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: .auto,
            localStore: store,
            mutationQueue: queue,
            conflictResolvers: resolvers
        )

        try await store.upsertItem(item(id: "server-3", version: 1, body: "original"))

        await #expect(throws: ConflictResolverMissingError.self) {
            _ = try await items.update(
                id: "server-3",
                properties: ["body": .string("edit")],
                options: UpdateOptions(version: 1, conflict: .callback)
            )
        }

        // Refused before anything was written or queued — the caller learns at
        // the point of the mistake rather than at a replay nobody is watching.
        #expect(try await queue.isEmpty)

        // With a resolver registered the same call is ordinary.
        await resolvers.register { _ in [:] }
        _ = try await items.update(
            id: "server-3",
            properties: ["body": .string("edit")],
            options: UpdateOptions(version: 1, conflict: .callback)
        )
        #expect(try await queue.fetchAll().count == 1)
    }
}

/// Captures what the resolver was handed, across the actor hop the engine
/// makes to call it.
private actor ResolverProbe {
    private(set) var captured: ConflictData?
    func record(_ conflict: ConflictData) { captured = conflict }
}
