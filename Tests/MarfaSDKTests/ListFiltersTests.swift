import Testing
import Foundation
@testable import MarfaSDK

@Suite("ListFilters query serialisation")
struct ListFiltersTests {

    // MARK: - tier

    @Test("tier filter omitted when nil")
    func tierNilOmitsParam() {
        let filters = ListFilters(type: "core.note")
        let params = filters.toQueryParams()
        #expect(!params.contains(where: { $0.0 == "tier" }))
    }

    @Test("tier filter serialises .library as \"library\"")
    func tierLibrary() {
        let filters = ListFilters(tier: .library)
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "tier" && $0.1 == "library" }))
    }

    @Test("tier filter serialises .feed as \"feed\"")
    func tierFeed() {
        let filters = ListFilters(tier: .feed)
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "tier" && $0.1 == "feed" }))
    }

    // MARK: - edge / backref

    @Test("edge filter serialises as edge[<type>]=<targetId>")
    func edgeFilter() {
        let filters = ListFilters(edge: ["parent-of": "parent-1"])
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "edge[parent-of]" && $0.1 == "parent-1" }))
    }

    @Test("backref filter serialises as backref[<type>]=<sourceId>")
    func backrefFilter() {
        let filters = ListFilters(backref: ["in-thread": "thread-1"])
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "backref[in-thread]" && $0.1 == "thread-1" }))
    }

    @Test("multiple edge keys serialise in sorted order for stable requests")
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

    // MARK: - sanity: retained fields still serialise

    @Test("basic fields still serialise after the prune")
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
