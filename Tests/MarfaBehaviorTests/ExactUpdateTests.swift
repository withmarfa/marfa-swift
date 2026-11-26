#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// An update queued exact, which the server refuses where the item has moved past the version it was based on.
///
/// The refusal after a drain needs a server, so `MarfaTests` covers it; these hold what the copy itself does.
@Suite(.timeLimit(.minutes(1)))
struct ExactUpdates {
    /// A copy that holds one note at version 4, as a server's answers would have left it, and the note's id.
    static func copyHoldingVersionFour(_ kind: CopyKind) async throws -> (copy: WorkingCopy, id: String) {
        let store = temporaryStore()
        let maker = try await WorkingCopy.open(store: store)
        let id = try await ItemsOffline.note("A", in: maker, tier: .library)
        await maker.close()
        try ItemsOffline.raise(store, to: 4)
        let real = try await WorkingCopy.open(store: store)
        switch kind {
        case .real:
            return (real, id)
        case .fake:
            let held = try #require(try await real.items.get(id))
            let types = try await real.catalog.itemTypes()
            await real.close()
            return (WorkingCopy.fake(items: [held], itemTypes: types).copy, id)
        }
    }

    @Test(arguments: CopyKind.allCases)
    func anExactUpdateOnTheHeldVersionIsQueuedAndSaysSo(kind: CopyKind) async throws {
        let (copy, id) = try await Self.copyHoldingVersionFour(kind)

        let write = try await copy.items.update(
            id, Edit(properties: ["title": "B"], baseVersion: 4, tier: .feed, exact: true))

        #expect(write.kind == .updateItem && write.baseVersion == 4)
        #expect(write.body == ["properties": ["title": "B"], "version": 4, "tier": "feed", "version_match": "exact"])
        let held = try #require(try await copy.items.get(id))
        #expect(held.title == "B" && held.tier == .feed)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anUpdateThatIsNotExactSaysNothingOfIt(kind: CopyKind) async throws {
        let (copy, id) = try await Self.copyHoldingVersionFour(kind)

        let write = try await copy.items.update(id, Edit(properties: ["title": "B"], baseVersion: 4))

        #expect(write.body == ["properties": ["title": "B"], "version": 4])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anExactUpdateOnAnEarlierVersionIsRefusedAsAVersionConflictAndQueuesNothing(kind: CopyKind) async throws {
        let (copy, id) = try await Self.copyHoldingVersionFour(kind)
        let before = try await copy.queue.all()
        func conflict(_ error: any Error) -> Bool {
            guard case .versionConflict(let message, let server)? = error as? MarfaError else { return false }
            return message.contains("version 4") && server == nil
        }

        await #expect(
            performing: {
                _ = try await copy.items.update(
                    id, Edit(properties: ["title": "B"], baseVersion: 3, exact: true))
            }, throws: conflict)
        await #expect(
            performing: {
                _ = try await copy.items.updateAsRead(
                    id, Edit(properties: ["title": "B"], baseVersion: 3, exact: true))
            }, throws: conflict)
        await #expect(
            performing: { _ = try await copy.items.updateAsRead(id, Edit(baseVersion: 1, exact: true)) },
            throws: conflict)

        #expect(try await copy.queue.all() == before)
        #expect(try await copy.items.get(id)?.title == "A")

        // The witness: the same edit, not exact, is queued and merged.
        let merged = try await copy.items.updateAsRead(id, Edit(properties: ["title": "B"], baseVersion: 3))
        #expect(merged.baseVersion == 3 && merged.body["version_match"] == nil)
        #expect(try await copy.items.get(id)?.title == "B")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anExactUpdateOnAVersionTheCopyHasNotReachedIsRefusedAsInvalid(kind: CopyKind) async throws {
        let (copy, id) = try await Self.copyHoldingVersionFour(kind)
        let before = try await copy.queue.all()

        for call in [copy.items.update, copy.items.updateAsRead] {
            await #expect {
                _ = try await call(id, Edit(properties: ["title": "B"], baseVersion: 5, exact: true))
            } throws: { ItemsOffline.invalid($0) }
        }

        #expect(try await copy.queue.all() == before)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anExactUpdateReadAtVersionZeroOfItsOwnCreateStaysBehindTheCreateWhileItIsUntaken(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let created = try await copy.items.create(
            Draft(type: "core.note", properties: ["title": "A", "body": "b"], tier: .feed))
        let id = try #require(created.itemId)

        let write = try await copy.items.updateAsRead(
            id, Edit(properties: ["title": "B"], baseVersion: 0, exact: true))

        #expect(write.baseVersion == 0 && write.dependsOn == [created.id])
        #expect(write.body["version_match"] == "exact")
        #expect(try await copy.items.get(id)?.title == "B")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anExactUpdateReadAtVersionZeroOfItsOwnTakenCreateIsBasedOnTheVersionTheCreateMade(
        kind: CopyKind
    ) async throws {
        let (copy, id, _) = try await ItemsOffline.copyThatTookItsOwnCreate(kind)

        let write = try await copy.items.updateAsRead(
            id, Edit(properties: ["title": "B"], baseVersion: 0, exact: true))

        #expect(write.baseVersion == 1 && write.body["version_match"] == "exact")
        let report = try await copy.queue.drain()
        #expect(report.verdicts.first { $0.id == write.id }?.verdict == .accepted)
        await copy.close()
    }
}
#endif
