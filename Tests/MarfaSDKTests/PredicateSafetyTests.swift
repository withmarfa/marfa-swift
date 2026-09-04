import Testing
import Foundation
import SwiftData
@_spi(MarfaSDKTestSupport) @testable import MarfaSDK
import MarfaSDKTestSupport

/// Regression suite for the `PredicateConventions.swift` ruleset.
///
/// Every supported pattern is exercised against an in-memory store; if a
/// future predicate drifts off the safe subset (e.g. someone reintroduces
/// `prop.isEmpty == false` or starts comparing against a Codable enum
/// case rather than its rawValue), the corresponding test fails loudly
/// instead of crashing at the first synced-mode end-to-end run.
///
/// Predicates that compile cleanly but crash at runtime under SwiftData
/// are the worst class of bug to catch in CI — these tests pin the
/// shapes the SDK depends on so a refactor can't quietly regress them.
@Suite("Predicate safety conventions")
struct PredicateSafetyTests {

    // MARK: - Helpers

    private func seededContext() async throws -> (ModelContext, ModelContainer) {
        let container = try MarfaSDKTest.makeInMemoryContainer()
        let context = ModelContext(container)
        // Seed a small, varied set: two notes (one active, one trashed)
        // and one task — enough to exercise every predicate shape with
        // discriminating filters.
        let active = MarfaItemModel()
        active.id = "a"
        active.type = "core.note"
        active.stateRaw = ItemState.active.rawValue
        active.createdAt = "2026-01-01T00:00:00.000Z"
        active.updatedAt = "2026-01-02T00:00:00.000Z"
        active.timestamp = active.createdAt
        active.source = "test"
        context.insert(active)

        let trashed = MarfaItemModel()
        trashed.id = "b"
        trashed.type = "core.note"
        trashed.stateRaw = ItemState.trashed.rawValue
        trashed.createdAt = "2026-01-03T00:00:00.000Z"
        trashed.updatedAt = "2026-01-04T00:00:00.000Z"
        trashed.timestamp = trashed.createdAt
        trashed.source = "test"
        context.insert(trashed)

        let task = MarfaItemModel()
        task.id = "c"
        task.type = "core.task"
        task.stateRaw = ItemState.active.rawValue
        task.createdAt = "2026-01-05T00:00:00.000Z"
        task.updatedAt = "2026-01-06T00:00:00.000Z"
        task.timestamp = task.createdAt
        task.source = "test"
        // The one row carrying a tier, so a filter naming every clause at once
        // can match a known id rather than matching nothing. A composed
        // predicate asserted to be empty pins only that it does not crash — a
        // lowering bug that wrongly excludes rows passes it identically.
        task.tierRaw = Tier.library.rawValue
        context.insert(task)

        try context.save()
        return (context, container)
    }

    // MARK: - Rule 7: Codable enum equality via rawValue

    @Test("State-raw rawValue predicate filters correctly") func stateRawPredicate() async throws {
        let (context, _) = try await seededContext()
        let activeRaw = ItemState.active.rawValue
        let predicate = #Predicate<MarfaItemModel> { $0.stateRaw == activeRaw }
        let descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        let results = try context.fetch(descriptor)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.state == .active })
    }

    // MARK: - Rule 8: Captured-value short-circuit composition

    @Test("Captured-value short-circuit pattern composes filters") func capturedShortCircuit() async throws {
        let (context, _) = try await seededContext()
        let typeFilter: String = "core.note"
        let hasTypeFilter = true
        let stateFilter: String = ItemState.active.rawValue
        let hasStateFilter = true

        let predicate = #Predicate<MarfaItemModel> { item in
            (!hasTypeFilter  || item.type == typeFilter) &&
            (!hasStateFilter || item.stateRaw == stateFilter)
        }
        let descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        let results = try context.fetch(descriptor)
        #expect(results.count == 1)
        #expect(results.first?.id == "a")
    }

    @Test("Captured-value short-circuit constant-true pass-through") func capturedShortCircuitPassThrough() async throws {
        let (context, _) = try await seededContext()
        // No filters set — every captured boolean is false, so the
        // entire predicate reduces to `true`. Constant-true branches
        // optimize away in the predicate engine.
        let typeFilter: String = ""
        let hasTypeFilter = false
        let stateFilter: String = ""
        let hasStateFilter = false

        let predicate = #Predicate<MarfaItemModel> { item in
            (!hasTypeFilter  || item.type == typeFilter) &&
            (!hasStateFilter || item.stateRaw == stateFilter)
        }
        let descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        let results = try context.fetch(descriptor)
        #expect(results.count == 3)
    }

    // MARK: - Captured-Set membership

    @Test("Set-contains over a captured Set filters correctly") func capturedSetContains() async throws {
        let (context, _) = try await seededContext()
        let ids: Set<String> = ["a", "c"]
        let predicate = #Predicate<MarfaItemModel> { ids.contains($0.id) }
        let descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        let results = try context.fetch(descriptor)
        #expect(results.count == 2)
        #expect(Set(results.map(\.id)) == ids)
    }

    // MARK: - String prefix (rule 5)

    @Test("starts(with:) compiles and filters correctly") func startsWith() async throws {
        let (context, _) = try await seededContext()
        let prefix = "core.no"
        let predicate = #Predicate<MarfaItemModel> { $0.type.starts(with: prefix) }
        let descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        let results = try context.fetch(descriptor)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.type == "core.note" })
    }

    @Test("Negated starts(with:) compiles and filters correctly") func negatedStartsWith() async throws {
        let (context, _) = try await seededContext()
        // Local search excludes `system.*` records this way. Negation of a
        // supported predicate operation is its own shape — pinned here so
        // it can't regress into a runtime crash.
        let prefix = "core.no"
        let predicate = #Predicate<MarfaItemModel> { !$0.type.starts(with: prefix) }
        let descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        let results = try context.fetch(descriptor)
        #expect(results.map(\.id) == ["c"])
    }

    @Test("Search descriptor composes every filter without crashing") func searchDescriptorShapes() async throws {
        let (context, _) = try await seededContext()

        // Unfiltered: `system.*` and trashed rows drop out by default.
        let unfiltered = try context.fetch(LocalStore.makeSearchDescriptor(filters: nil))
        #expect(Set(unfiltered.map(\.id)) == ["a", "c"])

        // Explicit state overrides the trashed exclusion.
        let trashed = try context.fetch(
            LocalStore.makeSearchDescriptor(filters: SearchFilters(state: .trashed))
        )
        #expect(trashed.map(\.id) == ["b"])

        // Every captured branch live at once.
        let everything = try context.fetch(
            LocalStore.makeSearchDescriptor(
                filters: SearchFilters(type: "core.note", state: .active, tier: .library)
            )
        )
        // The seed rows carry no tier, so a tier filter matches nothing —
        // the point here is that the composed predicate evaluates at all.
        #expect(everything.isEmpty)
    }

    /// The items descriptor's sibling witness. It composes more branches than
    /// the search one — seven now that `source` narrows — and the file it
    /// lives in warns twice that clause count is what pushes the `#Predicate`
    /// macro past the type-checker. A compile proves the macro accepted it;
    /// only a fetch proves the predicate *lowers*, which is the "compiles then
    /// crashes at runtime" failure this suite exists to catch.
    @Test("Items descriptor composes every filter without crashing") func itemsDescriptorShapes() async throws {
        let (context, _) = try await seededContext()

        // Unfiltered: `system.*` rows drop out, trashed ones do not — the
        // items descriptor has no default state exclusion where search does,
        // and that asymmetry is deliberate.
        let unfiltered = try context.fetch(LocalStore.makeItemsDescriptor(filters: nil))
        #expect(Set(unfiltered.map(\.id)) == ["a", "b", "c"])

        // Each captured branch alone, so a clause that stopped narrowing is
        // distinguishable from one that never matched.
        let byState = try context.fetch(
            LocalStore.makeItemsDescriptor(filters: ListFilters(state: .trashed))
        )
        #expect(byState.map(\.id) == ["b"])

        let bySource = try context.fetch(
            LocalStore.makeItemsDescriptor(filters: ListFilters(source: "test"))
        )
        #expect(Set(bySource.map(\.id)) == ["a", "b", "c"])

        let byMissingSource = try context.fetch(
            LocalStore.makeItemsDescriptor(filters: ListFilters(source: "no-such-source"))
        )
        #expect(byMissingSource.isEmpty)

        // Every captured branch live at once, and matching a known row rather
        // than matching nothing — so this pins that the composition *narrows*
        // as well as that it evaluates.
        var everything = ListFilters(type: "core.task", state: .active, tier: .library)
        everything.source = "test"
        everything.since = "2026-01-01T00:00:00.000Z"
        everything.until = "2026-12-31T00:00:00.000Z"
        let composed = try context.fetch(LocalStore.makeItemsDescriptor(filters: everything))
        #expect(composed.map(\.id) == ["c"])

        // And the same seven clauses with one value moved off the row, so the
        // assertion above cannot be satisfied by a predicate that stopped
        // narrowing at all.
        var narrowed = everything
        narrowed.source = "no-such-source"
        let none = try context.fetch(LocalStore.makeItemsDescriptor(filters: narrowed))
        #expect(none.isEmpty)
    }

    // MARK: - Range comparisons (used by since/until)

    @Test("String >= comparison filters correctly") func stringGreaterEqual() async throws {
        let (context, _) = try await seededContext()
        let since = "2026-01-04T00:00:00.000Z"
        let predicate = #Predicate<MarfaItemModel> { $0.updatedAt >= since }
        let descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
        let results = try context.fetch(descriptor)
        // `b.updatedAt = 2026-01-04…` and `c.updatedAt = 2026-01-06…`
        #expect(Set(results.map(\.id)) == ["b", "c"])
    }

    // MARK: - Relationship traversal in predicates (TagsQuery's pattern)

    @Test("Relationship traversal predicate filters by parent state") func relationshipTraversal() async throws {
        let (context, _) = try await seededContext()

        // Attach metadata to the active note (id="a") and the trashed
        // note (id="b"); leave the task without metadata.
        let metaA = MarfaMetadataModel()
        metaA.itemId = "a"
        metaA.tags = ["work"]
        let metaB = MarfaMetadataModel()
        metaB.itemId = "b"
        metaB.tags = ["work"]
        context.insert(metaA)
        context.insert(metaB)

        // Wire up the cascade-owning side of the relationship.
        let aPredicate = #Predicate<MarfaItemModel> { $0.id == "a" }
        let bPredicate = #Predicate<MarfaItemModel> { $0.id == "b" }
        try context.fetch(FetchDescriptor<MarfaItemModel>(predicate: aPredicate)).first?.metadata = metaA
        try context.fetch(FetchDescriptor<MarfaItemModel>(predicate: bPredicate)).first?.metadata = metaB
        try context.save()

        let trashedRaw = ItemState.trashed.rawValue
        let predicate = #Predicate<MarfaMetadataModel> { meta in
            meta.item != nil && meta.item?.stateRaw != trashedRaw
        }
        let results = try context.fetch(FetchDescriptor<MarfaMetadataModel>(predicate: predicate))
        // Only the metadata attached to the active note survives.
        #expect(results.count == 1)
        #expect(results.first?.itemId == "a")
    }

    // MARK: - Sort + limit on a fetched set

    @Test("FetchDescriptor sort + fetchLimit applies in order") func sortAndLimit() async throws {
        let (context, _) = try await seededContext()
        var descriptor = FetchDescriptor<MarfaItemModel>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 2
        let results = try context.fetch(descriptor)
        #expect(results.count == 2)
        // Newest first: c (Jan 6) then b (Jan 4).
        #expect(results.map(\.id) == ["c", "b"])
    }

    // MARK: - Empty-string filtering (predicate-safe equivalent)

    @Test("Empty-string filtering uses `!= \"\"` rather than isEmpty") func emptyStringFiltering() async throws {
        let (context, _) = try await seededContext()
        // Add one item with empty `source`, one with non-empty.
        let extra = MarfaItemModel()
        extra.id = "d"
        extra.type = "core.note"
        extra.stateRaw = ItemState.active.rawValue
        extra.createdAt = "2026-01-07T00:00:00.000Z"
        extra.updatedAt = "2026-01-07T00:00:00.000Z"
        extra.timestamp = extra.createdAt
        extra.source = ""
        context.insert(extra)
        try context.save()

        // SwiftData's predicate engine doesn't reliably lower
        // `String.isEmpty` (or its negation), so the SDK uses the
        // captured-value short-circuit pattern with explicit `!= ""`
        // comparisons. Predicate convention rule 1 calls out the
        // `isEmpty == false` form as a runtime crash; in practice
        // `!isEmpty` also misbehaves on String columns in current
        // SwiftData. The pattern we depend on:
        let empty = ""
        let predicate = #Predicate<MarfaItemModel> { $0.source != empty }
        let results = try context.fetch(FetchDescriptor<MarfaItemModel>(predicate: predicate))
        #expect(results.count == 3)
        #expect(!results.contains(where: { $0.id == "d" }))
    }

    // MARK: - DroppedMutationModel (5.2.0)

    /// Seeds three `DroppedMutationModel` rows with deliberately-spaced
    /// `droppedAt` strings, returning the `(context, ids)` so tests can
    /// assert against known identifiers.
    private func seededDroppedRows() async throws -> (ModelContext, [String]) {
        let container = try MarfaSDKTest.makeInMemoryContainer()
        let context = ModelContext(container)
        var ids: [String] = []
        let timestamps = [
            "2026-01-01T00:00:00.000Z",
            "2026-01-02T00:00:00.000Z",
            "2026-01-03T00:00:00.000Z",
        ]
        for stamp in timestamps {
            let row = DroppedMutationModel()
            row.id = UUID().uuidString
            row.kindRaw = MutationKind.deleteItem.rawValue
            row.payloadJson = "{}"
            row.localId = "item-\(stamp.prefix(10))"
            row.enqueuedAt = stamp
            row.droppedAt = stamp
            row.attemptCount = 1
            row.errorStatus = 400
            row.errorCode = "validation_error"
            row.errorMessage = "test"
            ids.append(row.id)
            context.insert(row)
        }
        try context.save()
        return (context, ids)
    }

    @Test("DroppedMutationModel sort by droppedAt descending returns newest first")
    func droppedSortDescending() async throws {
        let (context, _) = try await seededDroppedRows()
        let descriptor = FetchDescriptor<DroppedMutationModel>(
            sortBy: [SortDescriptor(\.droppedAt, order: .reverse)]
        )
        let rows = try context.fetch(descriptor)
        #expect(rows.count == 3)
        #expect(rows[0].droppedAt > rows[1].droppedAt)
        #expect(rows[1].droppedAt > rows[2].droppedAt)
    }

    @Test("DroppedMutationModel id-equality predicate filters correctly")
    func droppedIdEqualityPredicate() async throws {
        let (context, ids) = try await seededDroppedRows()
        let target = ids[1]
        let predicate = #Predicate<DroppedMutationModel> { $0.id == target }
        let rows = try context.fetch(FetchDescriptor<DroppedMutationModel>(predicate: predicate))
        #expect(rows.count == 1)
        #expect(rows.first?.id == target)
    }

    @Test("DroppedMutationModel droppedAt < cutoff lexicographic comparison")
    func droppedDroppedAtLexCompare() async throws {
        let (context, _) = try await seededDroppedRows()
        let cutoff = "2026-01-02T12:00:00.000Z" // between row 2 and row 3
        let predicate = #Predicate<DroppedMutationModel> { $0.droppedAt < cutoff }
        let rows = try context.fetch(FetchDescriptor<DroppedMutationModel>(predicate: predicate))
        // Two rows are strictly older than the cutoff (Jan 1 + Jan 2);
        // the Jan 3 row is preserved.
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.droppedAt < cutoff })
    }
}
