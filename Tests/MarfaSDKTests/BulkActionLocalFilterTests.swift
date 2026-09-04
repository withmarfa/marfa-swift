import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// A bulk action on a client with a store resolves its own match set, and the
/// narrowing it resolves has to be the narrowing the caller asked for.
///
/// Accepting a narrowing and dropping it is defensible for a listing — an
/// over-wide read shows extra rows and the next read corrects it. A bulk
/// action is not a read: it applies an action to every row the resolution
/// returned, and two of the six actions are `purge` and `transition`.
@Suite("Local bulk actions honor the narrowing they were given")
struct BulkActionLocalFilterTests {

    private func seedTwoNotes(_ client: MarfaClient) async throws {
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("first")])
        )
        _ = try await client.items.create(
            CreateItemInput(type: "core.note", properties: ["body": .string("second")])
        )
    }

    /// The expression grammar is the server's and is not implemented locally,
    /// so the action is refused rather than resolved without it.
    @Test("an expression filter is refused, not dropped")
    func expressionFilterIsRefused() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        do {
            _ = try await client.items.bulkAction(
                .transition(
                    filter: BulkActionFilter(filter: #"body eq "no-such-value""#),
                    state: .archived
                )
            )
            Issue.record("expected LocalFilterUnsupportedError")
        } catch let error as LocalFilterUnsupportedError {
            #expect(error.operation == "items.bulkAction")
            #expect(error.field == "filter")
        }
    }

    /// The refusal has to leave the store alone. A throw after the fan-out
    /// would be worse than the defect it replaces.
    @Test("a refused purge leaves every row where it was")
    func refusedPurgeChangesNothing() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        _ = try? await client.items.bulkAction(
            .purge(
                filter: BulkActionFilter(filter: #"body eq "no-such-value""#),
                options: BulkActionOptions(confirm: "PURGE")
            )
        )

        let remaining = try await client.items.list(filters: ListFilters(state: .active))
        #expect(remaining.data.count == 2)
    }

    /// `source` is a plain stored column, so it narrows rather than being
    /// refused — and narrowing to a value no row carries matches no rows.
    @Test("a source narrowing that matches nothing matches nothing")
    func sourceNarrows() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        let result = try await client.items.bulkAction(
            .transition(
                filter: BulkActionFilter(source: "no-such-source"),
                state: .archived
            )
        )

        #expect(result.matched == 0, "matched \(result.matched) rows for a source no row carries")
    }

    /// The discriminator for the test above: the same narrowing against a
    /// value rows *do* carry still finds them, so a zero is the filter working
    /// rather than the fetch returning nothing.
    @Test("a source narrowing that matches finds what it names")
    func sourceNarrowingFindsRealRows() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        try await seedTwoNotes(client)

        let seeded = try await client.items.list(filters: ListFilters(state: .active))
        let source = try #require(seeded.data.first?.source)

        let result = try await client.items.bulkAction(
            .transition(filter: BulkActionFilter(source: source), state: .archived)
        )

        #expect(result.matched == 2)
    }
}
