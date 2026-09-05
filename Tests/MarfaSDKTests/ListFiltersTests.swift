import Testing
import Foundation
@testable import MarfaSDK

@Suite("ListFilters query serialization")
struct ListFiltersTests {

    // MARK: - tier

    /// **The remote half of the trashed-row default**, which nothing else
    /// tested. The local store and the query string have to agree, and they
    /// are implemented in different files by different mechanisms — one drops
    /// a predicate clause, the other adds a parameter.
    @Test("includeTrashed sends state=any")
    func includeTrashedSendsAny() {
        let params = ListFilters(type: "core.note", includeTrashed: true).toQueryParams()
        #expect(params.contains { $0.0 == "state" && $0.1 == "any" })
    }

    /// A named state wins, because it is the narrower request. Inverting the
    /// branch would send `any` and return rows the caller excluded.
    @Test("a named state beats includeTrashed on the wire")
    func namedStateWinsOnTheWire() {
        let params = ListFilters(state: .trashed, includeTrashed: true).toQueryParams()
        #expect(params.contains { $0.0 == "state" && $0.1 == "trashed" })
        #expect(!params.contains { $0.0 == "state" && $0.1 == "any" })
    }

    /// Absent by default, so an ordinary list keeps the server's own default
    /// rather than asking for everything.
    @Test("no state parameter is sent when neither is set")
    func noStateParameterByDefault() {
        let params = ListFilters(type: "core.note").toQueryParams()
        #expect(!params.contains { $0.0 == "state" })
    }

    @Test("tier filter omitted when nil")
    func tierNilOmitsParam() {
        let filters = ListFilters(type: "core.note")
        let params = filters.toQueryParams()
        #expect(!params.contains(where: { $0.0 == "tier" }))
    }

    @Test("tier filter serializes .library as \"library\"")
    func tierLibrary() {
        let filters = ListFilters(tier: .library)
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "tier" && $0.1 == "library" }))
    }

    @Test("tier filter serializes .feed as \"feed\"")
    func tierFeed() {
        let filters = ListFilters(tier: .feed)
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "tier" && $0.1 == "feed" }))
    }

    // MARK: - edge / backref

    @Test("edge filter serializes as edge[<type>]=<targetId>")
    func edgeFilter() {
        let filters = ListFilters(edge: ["parent-of": "parent-1"])
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "edge[parent-of]" && $0.1 == "parent-1" }))
    }

    @Test("backref filter serializes as backref[<type>]=<sourceId>")
    func backrefFilter() {
        let filters = ListFilters(backref: ["in-thread": "thread-1"])
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "backref[in-thread]" && $0.1 == "thread-1" }))
    }

    @Test("multiple edge keys serialize in sorted order for stable requests")
    func edgeFilterSorted() {
        let filters = ListFilters(edge: ["zzz": "z1", "aaa": "a1", "mmm": "m1"])
        let params = filters.toQueryParams()
        let edgeKeys = params.filter { $0.0.hasPrefix("edge[") }.map { $0.0 }
        #expect(edgeKeys == ["edge[aaa]", "edge[mmm]", "edge[zzz]"])
    }

    @Test("empty edge/backref dicts emit no query keys")
    func emptyDictsNoParams() {
        let filters = ListFilters(edge: [:], backref: [:])
        let params = filters.toQueryParams()
        #expect(!params.contains(where: { $0.0.hasPrefix("edge[") }))
        #expect(!params.contains(where: { $0.0.hasPrefix("backref[") }))
    }

    // MARK: - sanity: retained fields still serialize

    @Test("basic fields still serialize after the prune")
    func coreFieldsUnchanged() {
        let filters = ListFilters(
            type: "core.note",
            state: .active,
            source: "sdk",
            tags: ["a", "b"],
            sort: .createdAt,
            direction: .descending,
            limit: 25,
            cursor: "c1"
        )
        let params = filters.toQueryParams()
        let keys = Set(params.map { $0.0 })
        #expect(keys.isSuperset(of: [
            "type", "state", "source", "tags",
            "sort", "direction", "limit", "cursor",
        ]))
    }
}
