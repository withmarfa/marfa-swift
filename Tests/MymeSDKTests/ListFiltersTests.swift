import Testing
import Foundation
@testable import MymeSDK

@Suite("ListFilters query serialisation")
struct ListFiltersTests {

    // MARK: - library

    @Test("library filter omitted when nil")
    func libraryNilOmitsParam() {
        let filters = ListFilters(type: "core.note")
        let params = filters.toQueryParams()
        #expect(!params.contains(where: { $0.0 == "library" }))
    }

    @Test("library filter serialises .library as \"true\"")
    func libraryTrue() {
        let filters = ListFilters(library: .library)
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "library" && $0.1 == "true" }))
    }

    @Test("library filter serialises .ambient as \"false\"")
    func libraryFalse() {
        let filters = ListFilters(library: .ambient)
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "library" && $0.1 == "false" }))
    }

    @Test("library filter serialises .all as \"all\"")
    func libraryAll() {
        let filters = ListFilters(library: .all)
        let params = filters.toQueryParams()
        #expect(params.contains(where: { $0.0 == "library" && $0.1 == "all" }))
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
