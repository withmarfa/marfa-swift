import Testing
import Foundation
@testable import MarfaSDK

/// The names a time-bounded read puts on the wire.
///
/// Nothing pinned these, which is why they could be wrong against every
/// current server without a single test noticing: the SDK's own fixtures
/// never look at a query string, and the one suite that talks to a real
/// server never sends a time bound. The refusal was correct and loud at the
/// server, and a refusal nobody's tests reach looks exactly like a feature
/// nobody uses.
@Suite("Time filters put the server's names on the wire", .timeLimit(.minutes(1)))
struct TimeFilterWireNamesTests {

    @Test("a list filter emits timestamp_after and timestamp_before")
    func listFilterNames() {
        var filters = ListFilters()
        filters.timestampAfter = "2026-01-01T00:00:00Z"
        filters.timestampBefore = "2026-12-31T00:00:00Z"

        let names = Dictionary(uniqueKeysWithValues: filters.toQueryParams())
        #expect(names["timestamp_after"] == "2026-01-01T00:00:00Z")
        #expect(names["timestamp_before"] == "2026-12-31T00:00:00Z")

        // The names the server refuses with a 400, each naming its
        // replacement. Their absence is the assertion that matters: a filter
        // carrying one of these cannot succeed against any current server.
        #expect(names["since"] == nil)
        #expect(names["until"] == nil)
    }

    /// The discriminator: an unset bound emits nothing, so the assertions
    /// above are about the names rather than about the map being empty.
    @Test("an unset bound emits no parameter at all")
    func unsetEmitsNothing() {
        let names = Dictionary(uniqueKeysWithValues: ListFilters().toQueryParams())
        #expect(names["timestamp_after"] == nil)
        #expect(names["timestamp_before"] == nil)
    }

    /// A bulk action's filter is encoded rather than serialized to a query, so
    /// it is pinned at the JSON it sends.
    @Test("a bulk action filter encodes timestamp_after and timestamp_before")
    func bulkFilterNames() throws {
        let input = BulkActionInput.transition(
            filter: BulkActionFilter(
                timestampAfter: "2026-01-01T00:00:00Z",
                timestampBefore: "2026-12-31T00:00:00Z"
            ),
            state: .archived
        )
        let encoded = try JSONEncoder().encode(input)
        let json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let filter = try #require(json["filter"] as? [String: Any])

        #expect(filter["timestamp_after"] as? String == "2026-01-01T00:00:00Z")
        #expect(filter["timestamp_before"] as? String == "2026-12-31T00:00:00Z")
        #expect(filter["since"] == nil)
        #expect(filter["until"] == nil)
    }
}
