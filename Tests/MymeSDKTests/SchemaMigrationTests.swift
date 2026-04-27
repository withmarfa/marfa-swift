import Testing
import Foundation
@testable import MymeSDK
@_spi(MymeSDKTestSupport) import MymeSDK
@testable import MymeSDKTestSupport
import SwiftData

/// First migration test in the SDK. Verifies the V1 → V2 lightweight
/// stage shipped in 5.2.0:
///
/// - A V1 store on disk seeded with rows can be reopened against the
///   V2 schema via the migration plan.
/// - Existing rows survive untouched.
/// - The new ``DroppedMutationModel`` table is queryable and starts
///   empty.
///
/// File-on-disk shape (not in-memory) — the migration plan only fires
/// on persistent stores. Each test runs in its own temp directory so
/// the suite stays hermetic and can run in parallel with the rest.
@Suite("SchemaMigration")
struct SchemaMigrationTests {

    /// Allocates a unique on-disk path under the system temp directory
    /// and returns it. Caller is responsible for tearing the file down
    /// (`removeStoreFiles`) after they're done with the container.
    private func makeTempStorePath() -> String {
        NSTemporaryDirectory() + "myme-migration-\(UUID().uuidString).sqlite"
    }

    /// Removes the SQLite file plus its `-wal` / `-shm` siblings.
    /// Mirrors ``MymeModelContainer/removeStoreFiles(at:)``.
    private func removeStoreFiles(at path: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: path + suffix)
        }
    }

    /// Builds a V1-only container at `path` (no migration plan,
    /// schema fixed at V1). Used to seed a known-V1 store before the
    /// V2 migration test reopens it.
    private func makeV1ContainerOnDisk(at path: String) throws -> ModelContainer {
        let url = URL(fileURLWithPath: path)
        return try ModelContainer(
            for: Schema(MymeSchemaV1.models),
            configurations: ModelConfiguration(
                "myme",
                schema: Schema(MymeSchemaV1.models),
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        )
    }

    @Test("V1 store opens cleanly under the V2 migration plan and rows survive")
    func v1StoreMigratesToV2() async throws {
        let path = makeTempStorePath()
        defer { removeStoreFiles(at: path) }

        // Phase 1 — seed a V1 store on disk.
        do {
            let v1 = try makeV1ContainerOnDisk(at: path)
            let context = ModelContext(v1)

            // One PendingMutationModel — exercises the row schema that
            // didn't change between V1 and V2 (regression guard against
            // a future lightweight-migration mis-step that drops or
            // reshapes existing tables).
            let pending = PendingMutationModel()
            pending.id = UUID().uuidString
            pending.kindRaw = MutationKind.deleteItem.rawValue
            pending.payloadJson = #"{"id":"server-x"}"#
            pending.localId = "server-x"
            pending.createdAt = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            pending.attemptCount = 0
            pending.stateRaw = PendingMutationState.pending.rawValue
            context.insert(pending)

            // One SyncStateModel row — checks the cursor / clean-drain
            // bookkeeping survives migration.
            let cursor = SyncStateModel()
            cursor.key = "last_event_id"
            cursor.value = "evt-42"
            context.insert(cursor)

            try context.save()
        }

        // Phase 2 — reopen via MymeModelContainer.make, which uses the
        // V2 schema + migration plan.
        let v2 = try MymeModelContainer.make(path: path)
        let context = ModelContext(v2)

        // Existing rows survived.
        let pendingDescriptor = FetchDescriptor<PendingMutationModel>()
        let pending = try context.fetch(pendingDescriptor)
        #expect(pending.count == 1)
        #expect(pending.first?.localId == "server-x")
        #expect(pending.first?.kind == .deleteItem)

        let stateDescriptor = FetchDescriptor<SyncStateModel>()
        let state = try context.fetch(stateDescriptor)
        #expect(state.count == 1)
        #expect(state.first?.key == "last_event_id")
        #expect(state.first?.value == "evt-42")

        // New table exists and is queryable + empty.
        let droppedDescriptor = FetchDescriptor<DroppedMutationModel>()
        let dropped = try context.fetch(droppedDescriptor)
        #expect(dropped.isEmpty)

        // Inserts into the new table succeed under the migrated container.
        let stamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let drop = DroppedMutationModel()
        drop.id = UUID().uuidString
        drop.kindRaw = MutationKind.updateItem.rawValue
        drop.payloadJson = "{}"
        drop.localId = "server-y"
        drop.enqueuedAt = stamp
        drop.droppedAt = stamp
        drop.attemptCount = 1
        drop.errorStatus = 400
        drop.errorCode = "validation_error"
        drop.errorMessage = "post-migration insert"
        context.insert(drop)
        try context.save()

        let droppedAfterInsert = try context.fetch(droppedDescriptor)
        #expect(droppedAfterInsert.count == 1)
    }

    @Test("V2 schema lists every V1 model plus DroppedMutationModel")
    func v2SchemaIsAdditiveOverV1() {
        let v1Names = Set(MymeSchemaV1.models.map { String(describing: $0) })
        let v2Names = Set(MymeSchemaV2.models.map { String(describing: $0) })
        #expect(v1Names.isSubset(of: v2Names))
        #expect(v2Names.subtracting(v1Names) == ["DroppedMutationModel"])
    }
}
