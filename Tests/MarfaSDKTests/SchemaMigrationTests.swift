import Testing
import Foundation
import CoreData
import SQLite3
@testable import MarfaSDK
@_spi(MarfaSDKTestSupport) import MarfaSDK
@testable import MarfaSDKTestSupport
import SwiftData

/// The migration plan, checked against a store a shipped build actually wrote.
///
/// **Nothing here instantiates a frozen model class, and that is a hard
/// constraint rather than a preference.** Two `@Model` classes can share an
/// entity name — that is what makes a versioned schema work at all — but
/// SwiftData keys part of its runtime state by that name, so creating an object
/// of the frozen class in a process that also creates objects of the live one
/// leaves the two able to be confused. What it looks like is an
/// `NSUnknownKeyException` naming the column the newest version added, thrown
/// from an insert that never mentions it, in whichever test happens to run
/// next. It needs the whole suite's ordering to appear and is invisible when
/// this file runs on its own, which is why it is written down here rather than
/// left to be rediscovered.
///
/// None of that reaches an app. A device only ever instantiates the live
/// classes; the frozen ones exist as entity *descriptions* inside SwiftData's
/// own migration machinery, which is a different thing and is exercised end to
/// end by `ShippedStoreFixtureTests` against a real V2 store.
///
/// So the old store here is the committed fixture rather than one seeded
/// through frozen classes, and what it holds afterwards is read with SQLite
/// rather than fetched. Reading the columns is the stronger assertion anyway:
/// `spaceId` coming back `nil` says as much about a fetch that returned nothing
/// as about the migration, while the column being present in `ZMARFAITEMMODEL`
/// says one thing only. The round trip through the live classes is covered on a
/// fresh store in `ItemLayeringRoundTripTests`, where no frozen version exists.
///
/// **V1 is not exercised, and cannot be.** `MarfaSchemaV1` as this build
/// compiles it describes no store that ever shipped: 7.0.0 dropped a column
/// from the item model in place without moving the version identifier, so a
/// store written while V1 was current hashes differently from V1 as it stands.
/// The only way to produce one now is to seed it through the frozen classes,
/// which is the thing above. The stage is kept for lineage.
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

    /// The committed V2 store, at the path the test may write to. Opening a
    /// store migrates it in place, so the checked-in copy is never the one
    /// under test.
    private func stagedV2Store() throws -> String {
        let source = try #require(
            Bundle.module.url(
                forResource: "store",
                withExtension: "sqlite",
                subdirectory: "Fixtures/ShippedStore"
            ),
            "the store fixture is not in the test bundle"
        )
        let path = makeTempStorePath()
        try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: path))
        return path
    }

    @Test("a V2 store migrates to V3 and gains the item's space id and the cached-types table")
    func v2StoreMigratesToV3() throws {
        let path = try stagedV2Store()
        defer { removeStoreDirectory(of: path) }
        let store = URL(fileURLWithPath: path)

        // Neither is there yet, or what follows would pass against a store the
        // migration never touched.
        #expect(!(try columns(of: "ZMARFAITEMMODEL", in: store).contains("ZSPACEID")))
        #expect(!(try tables(in: store).contains("ZCACHEDTYPEMODEL")))
        #expect(try QuarantinedStoreReader.read(storeAt: store).rows("pendingMutations").count == 1)

        do { _ = try MarfaModelContainer.make(path: path) }

        #expect(try columns(of: "ZMARFAITEMMODEL", in: store).contains("ZSPACEID"))
        #expect(try tables(in: store).contains("ZCACHEDTYPEMODEL"))

        // The rows the migration had to carry across. `ShippedStoreFixtureTests`
        // checks every row in the store through the model layer; what is
        // checked here is the ones that exist nowhere but this device.
        let salvage = try QuarantinedStoreReader.read(storeAt: store)
        #expect(salvage.rows("pendingMutations").count == 1)
        #expect(salvage.rows("droppedMutations").count == 1)
        #expect(salvage.rows("pendingBlobs").count == 1)
        #expect(salvage.rows("syncState").first?["value"]?.stringValue == "evt-42")
        #expect(try rowCount(of: "ZMARFAITEMMODEL", in: store) == 1)
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
    /// wrote, by the hashes that store recorded for itself. Building a
    /// container over the frozen version creates entity descriptions and no
    /// objects, which is the distinction the suite docblock turns on.
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
        do {
            let schema = Schema(versionedSchema: MarfaSchemaV2.self)
            _ = try MarfaModelContainer.withCreationLock {
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

    // MARK: - Reading a store without a model

    /// Opens the store read-write without `SQLITE_OPEN_CREATE`, so a path that
    /// holds no database fails rather than becoming an empty one. Read-write
    /// rather than read-only because a WAL store needs its shared-memory index
    /// to be readable at all.
    private func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw StoreReadFailure(message: message)
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private struct StoreReadFailure: Error { let message: String }

    private func query(_ sql: String, in url: URL) throws -> [String] {
        try withDatabase(at: url) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw StoreReadFailure(message: String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            var out: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { continue }
                out.append(String(cString: text))
            }
            return out
        }
    }

    private func tables(in url: URL) throws -> Set<String> {
        Set(try query("SELECT name FROM sqlite_master WHERE type = 'table'", in: url))
    }

    private func columns(of table: String, in url: URL) throws -> Set<String> {
        Set(try query("SELECT name FROM pragma_table_info('\(table)')", in: url))
    }

    private func rowCount(of table: String, in url: URL) throws -> Int {
        Int(try query("SELECT COUNT(*) FROM \(table)", in: url).first ?? "0") ?? 0
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
