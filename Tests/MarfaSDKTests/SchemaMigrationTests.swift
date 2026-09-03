import Testing
import Foundation
import CoreData
@testable import MarfaSDK
@_spi(MarfaSDKTestSupport) import MarfaSDK
@testable import MarfaSDKTestSupport
import SwiftData

/// The migration plan, checked against stores built at the shapes it claims to
/// migrate from.
///
/// A store seeded through the live classes would already have the current
/// shape, and reopening it would compare the schema against itself. Every
/// store here is seeded through the frozen copies in ``FrozenV2``, which is
/// what makes the comparison real — and is also why those copies are pinned by
/// a test of their own below.
///
/// File-on-disk shape (not in-memory) — the migration plan only fires on
/// persistent stores. Each test runs in its own temp directory so the suite
/// stays hermetic and can run in parallel with the rest.
@Suite("SchemaMigration")
struct SchemaMigrationTests {

    /// Allocates a directory of this test's own and returns a store path
    /// inside it. Caller tears down the whole directory with
    /// ``removeStoreDirectory(of:)``.
    ///
    /// A directory rather than a bare path in the system temp root,
    /// because the store is not the only thing that lands on disk. Opening
    /// a SwiftData container on a file URL makes Foundation create
    /// item-replacement directories beside the target, and nothing removes
    /// those — measured at six per run of this suite alone, and ten
    /// thousand accumulated in user temp before anybody looked. Removing
    /// the sqlite file and its siblings, which is all this used to do,
    /// left every one of them behind.
    private func makeTempStorePath() -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marfa-migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("store.sqlite").path
    }

    /// Removes the directory the store and everything created beside it
    /// live in. One call, every exit path, whatever the framework put there.
    private func removeStoreDirectory(of path: String) {
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds a container at `path` fixed to one historical version, with no
    /// migration plan. Used to seed a store of a known age before the current
    /// schema reopens it.
    private func makeContainer(
        at path: String,
        for version: any VersionedSchema.Type
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: version)
        return try MarfaModelContainer.withCreationLock {
            try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    "marfa",
                    schema: schema,
                    url: URL(fileURLWithPath: path),
                    allowsSave: true,
                    cloudKitDatabase: .none
                )
            )
        }
    }

    /// One queued write and one cursor row, through the frozen classes — the
    /// two things a migration that reshapes tables would be caught losing.
    private func seedQueueAndCursor(into context: ModelContext, localId: String) throws {
        let pending = FrozenV2.PendingMutationModel()
        pending.id = UUID().uuidString
        pending.kindRaw = MutationKind.deleteItem.rawValue
        pending.payloadJson = #"{"id":"\#(localId)"}"#
        pending.localId = localId
        pending.createdAt = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        pending.attemptCount = 0
        pending.stateRaw = PendingMutationState.pending.rawValue
        context.insert(pending)

        let cursor = FrozenV2.SyncStateModel()
        cursor.key = "last_event_id"
        cursor.value = "evt-42"
        context.insert(cursor)

        try context.save()
    }

    @Test("a V1 store migrates forward and its queued write and cursor survive")
    func v1StoreMigratesForward() async throws {
        let path = makeTempStorePath()
        defer { removeStoreDirectory(of: path) }

        do {
            let v1 = try makeContainer(at: path, for: MarfaSchemaV1.self)
            try seedQueueAndCursor(into: ModelContext(v1), localId: "server-x")
        }

        let context = ModelContext(try MarfaModelContainer.make(path: path))

        let pending = try context.fetch(FetchDescriptor<PendingMutationModel>())
        #expect(pending.count == 1)
        #expect(pending.first?.localId == "server-x")
        #expect(pending.first?.kind == .deleteItem)

        let state = try context.fetch(FetchDescriptor<SyncStateModel>())
        #expect(state.count == 1)
        #expect(state.first?.key == "last_event_id")
        #expect(state.first?.value == "evt-42")

        // Both tables V1 never had, queryable and empty. A lightweight stage
        // that failed to add one would fail here rather than at the first
        // write on a device.
        #expect(try context.fetch(FetchDescriptor<DroppedMutationModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CachedTypeModel>()).isEmpty)
    }

    @Test("a V2 store migrates to V3 and gains the item's space id and the cached-types table")
    func v2StoreMigratesToV3() async throws {
        let path = makeTempStorePath()
        defer { removeStoreDirectory(of: path) }

        let itemId = "019eb100-0000-7000-8000-0000000000aa"
        do {
            let v2 = try makeContainer(at: path, for: MarfaSchemaV2.self)
            let context = ModelContext(v2)
            try seedQueueAndCursor(into: context, localId: itemId)

            // A V2 item has no space column at all, so what the migration has
            // to produce is a row that reads `nil` rather than one that fails
            // to read.
            let item = FrozenV2.MarfaItemModel()
            item.id = itemId
            item.type = "core.note"
            item.source = "fixture"
            context.insert(item)
            try context.save()
        }

        // Scoped, one container at a time. Two live containers on one store
        // file in one process is the arrangement that produces SwiftData's
        // "failed to cast model" crash, and it is easy to write by accident
        // when a test wants to reopen something.
        do {
            let migrated = try MarfaModelContainer.make(path: path)
            let context = ModelContext(migrated)

            let items = try context.fetch(FetchDescriptor<MarfaItemModel>())
            #expect(items.count == 1)
            #expect(items.first?.id == itemId)
            #expect(items.first?.spaceId == nil)
            #expect(try context.fetch(FetchDescriptor<PendingMutationModel>()).count == 1)

            // The new column takes a value, and the new table takes a row.
            items.first?.spaceId = "space-1"
            let cached = CachedTypeModel()
            cached.id = "myapp.thing"
            cached.parent = "core.note"
            cached.definitionJson = #"{"id":"myapp.thing"}"#
            cached.cachedAt = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            context.insert(cached)
            try context.save()
        }

        // Reopened, so both are read back off disk rather than out of a
        // context that still remembers writing them.
        let reopened = ModelContext(try MarfaModelContainer.make(path: path))
        #expect(try reopened.fetch(FetchDescriptor<MarfaItemModel>()).first?.spaceId == "space-1")
        #expect(try reopened.fetch(FetchDescriptor<CachedTypeModel>()).first?.id == "myapp.thing")
    }

    @Test("each schema version lists the models that version's stores actually hold")
    func versionsListTheRightModels() {
        let v1 = Set(MarfaSchemaV1.models.map { String(describing: $0) })
        let v2 = Set(MarfaSchemaV2.models.map { String(describing: $0) })
        let v3 = Set(MarfaSchemaV3.models.map { String(describing: $0) })
        #expect(v1.isSubset(of: v2))
        #expect(v2.subtracting(v1) == ["DroppedMutationModel"])
        #expect(v2.isSubset(of: v3))
        #expect(v3.subtracting(v2) == ["CachedTypeModel"])
    }

    /// The frozen copies are the whole mechanism, and nothing about them looks
    /// load-bearing to a reader who meets them cold.
    ///
    /// Editing ``FrozenV2`` — even to "keep it in sync" with a live model —
    /// changes what V2 hashes to. Core Data then matches no version to a real
    /// V2 store, the stage that would have migrated it never applies, and the
    /// device takes the fail-safe path instead. Nothing fails at build time
    /// and nothing fails on a fresh install, which is every machine that would
    /// have caught it.
    ///
    /// So the copies are compared against a store a shipped V2 build actually
    /// wrote, by the hashes that store recorded for itself.
    @Test("the frozen V2 models still hash the way a shipped V2 store does")
    func frozenModelsMatchAShippedV2Store() throws {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "store",
                withExtension: "sqlite",
                subdirectory: "Fixtures/ShippedStore"
            ),
            "the store fixture is not in the test bundle"
        )
        let shipped = try recordedHashes(at: fixture)

        let path = makeTempStorePath()
        defer { removeStoreDirectory(of: path) }
        // Scoped so the container is released and the store checkpointed
        // before its metadata is read.
        do { _ = try makeContainer(at: path, for: MarfaSchemaV2.self) }
        let frozen = try recordedHashes(at: URL(fileURLWithPath: path))

        // Entity names first. If a rename reached the name, every hash differs
        // for an uninteresting reason and the comparison below says nothing.
        #expect(
            Set(frozen.keys) == Set(shipped.keys),
            "entity names differ: frozen \(Set(frozen.keys).sorted()) vs shipped \(Set(shipped.keys).sorted())"
        )
        // Then per entity, so a failure names which copy drifted rather than
        // reporting one opaque inequality.
        for name in Set(shipped.keys).sorted() {
            #expect(frozen[name] == shipped[name], "\(name) no longer hashes the way a V2 store holds it")
        }
    }

    /// Reads the version hashes a store recorded, without opening it under a
    /// model. `metadataForPersistentStore` is a metadata read rather than a
    /// compatibility-checked open, so it answers for a store the current
    /// schema would refuse.
    private func recordedHashes(at url: URL) throws -> [String: Data] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url, options: nil
        )
        return metadata["NSStoreModelVersionHashes"] as? [String: Data] ?? [:]
    }
}
