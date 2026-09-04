import Testing
import Foundation
@testable import MarfaSDK

/// What the kit *sends*, checked against what the server declares it accepts.
///
/// **This is the guard that did not exist, and its absence is why two wire
/// renames shipped silently.** The response side has had one for a while:
/// `WireFixtureSpecDriftTests` walks decoded fixtures against response
/// schemas, and it is what caught an edge gaining a version and a conflict
/// envelope gaining a message the moment the snapshot moved. Nothing did the
/// same for requests, so a renamed query parameter and a renamed request-body
/// field both passed every check in the repository.
///
/// The two failure modes differ and both are ugly. `since` was *refused* with
/// a 400, so every date-bounded read failed loudly at the server and silently
/// in the suite. `emit_events` was *discarded* — the route declares no
/// additional properties but does not reject them — so a caller asking for
/// webhook fanout got a success result and no webhooks.
///
/// **What this cannot see**, stated in the same breath as what it delivers: it
/// checks names, not types, not required-ness, and not values. It reads the
/// vendored snapshot, so it is only as current as the last `sync-openapi.sh` —
/// the `Spec drift` workflow is what says whether that is current. And it
/// covers the inputs named below rather than every encodable in the kit,
/// because each has to be constructed with every field populated for its keys
/// to appear at all.
@Suite("What the kit sends is what the server declares", .timeLimit(.minutes(1)))
struct RequestSpecDriftTests {

    private var packageRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    private func spec() throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("scripts/openapi.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every query parameter the spec declares for one operation.
    private func declaredQueryNames(_ spec: [String: Any], method: String, path: String) throws -> Set<String> {
        let paths = try #require(spec["paths"] as? [String: Any])
        let route = try #require(paths[path] as? [String: Any], "spec declares no \(path)")
        let operation = try #require(route[method] as? [String: Any], "spec declares no \(method) \(path)")
        let parameters = operation["parameters"] as? [[String: Any]] ?? []
        return Set(
            parameters
                .filter { $0["in"] as? String == "query" }
                .compactMap { $0["name"] as? String }
        )
    }

    /// Every property name the spec declares on one operation's request body,
    /// flattened across `oneOf` and `anyOf` branches, one level of nesting
    /// deep — enough to reach a `filter` object or an `options` block.
    private func declaredBodyNames(_ spec: [String: Any], method: String, path: String) throws -> Set<String> {
        let paths = try #require(spec["paths"] as? [String: Any])
        let route = try #require(paths[path] as? [String: Any], "spec declares no \(path)")
        let operation = try #require(route[method] as? [String: Any], "spec declares no \(method) \(path)")
        let body = try #require(operation["requestBody"] as? [String: Any], "no request body on \(method) \(path)")
        let content = try #require(body["content"] as? [String: Any])
        let json = try #require(content["application/json"] as? [String: Any])
        let schema = try #require(json["schema"] as? [String: Any])

        var names: Set<String> = []
        func walk(_ node: Any, depth: Int) {
            guard depth <= 2, let object = node as? [String: Any] else { return }
            if let properties = object["properties"] as? [String: Any] {
                names.formUnion(properties.keys)
                for value in properties.values { walk(value, depth: depth + 1) }
            }
            for key in ["oneOf", "anyOf", "allOf"] {
                for branch in object[key] as? [[String: Any]] ?? [] { walk(branch, depth: depth) }
            }
        }
        walk(schema, depth: 0)
        return names
    }

    /// The keys an encodable actually puts on the wire.
    private func encodedKeys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var names = Set(object.keys)
        for nested in object.values {
            if let child = nested as? [String: Any] { names.formUnion(child.keys) }
        }
        return names
    }

    // MARK: - Query parameters

    /// The one that would have caught `since` and `until`.
    @Test("every list filter parameter is one GET /items declares")
    func listFiltersMatchTheSpec() throws {
        let declared = try declaredQueryNames(try spec(), method: "get", path: "/items")

        // Populated on every axis, because a nil field emits nothing and an
        // unpopulated filter would assert about an empty set.
        var filters = ListFilters(
            type: "core.note", state: .active, source: "seed", tier: .library,
            tags: ["a"], sort: .createdAt, direction: .descending, limit: 10, cursor: "c"
        )
        filters.timestampAfter = "2026-01-01T00:00:00Z"
        filters.timestampBefore = "2026-12-31T00:00:00Z"
        filters.filter = #"body eq "x""#
        filters.edge = ["core.about": "id"]
        filters.backref = ["core.reply": "id"]

        let emitted = Set(filters.toQueryParams().map(\.0))
        #expect(emitted.isEmpty == false, "the filter emitted nothing, so this asserts about nothing")

        // `edge[...]`/`backref[...]` are a bracketed shorthand the spec cannot
        // declare as a fixed name, so they are excluded by prefix rather than
        // by listing them — a new bracketed family stays covered.
        let checkable = emitted.filter { !$0.contains("[") }
        let undeclared = checkable.subtracting(declared)
        #expect(undeclared.isEmpty, "the kit sends query parameters GET /items does not declare: \(undeclared.sorted())")
    }

    // MARK: - Request bodies

    /// The one that would have caught `emit_events`.
    @Test("every bulk-action field is one POST /items/bulk-actions declares")
    func bulkActionFieldsMatchTheSpec() throws {
        let declared = try declaredBodyNames(try spec(), method: "post", path: "/items/bulk-actions")

        let input = BulkActionInput.transition(
            filter: BulkActionFilter(
                type: "core.note", state: .active, source: "seed", tier: .library,
                tags: ["a"], timestampAfter: "2026-01-01T00:00:00Z",
                timestampBefore: "2026-12-31T00:00:00Z", filter: #"body eq "x""#
            ),
            state: .archived,
            options: BulkActionOptions(dryRun: true, maxItems: 10, enableFanout: true)
        )

        let emitted = try encodedKeys(input)
        #expect(emitted.isEmpty == false)
        let undeclared = emitted.subtracting(declared)
        #expect(undeclared.isEmpty, "the kit sends bulk-action fields the route does not declare: \(undeclared.sorted())")
    }

    @Test("every bulk-items field is one POST /items/bulk declares")
    func bulkItemsFieldsMatchTheSpec() throws {
        let declared = try declaredBodyNames(try spec(), method: "post", path: "/items/bulk")

        let input = BulkInput(
            items: [BulkItemInput(type: "core.note")],
            mode: .upsert, atomic: true, enableFanout: true
        )
        let emitted = try encodedKeys(input)
        #expect(emitted.isEmpty == false)
        let undeclared = emitted.subtracting(declared)
        #expect(undeclared.isEmpty, "the kit sends bulk-items fields the route does not declare: \(undeclared.sorted())")
    }

    @Test("every bulk-edges field is one POST /edges/bulk declares")
    func bulkEdgesFieldsMatchTheSpec() throws {
        let declared = try declaredBodyNames(try spec(), method: "post", path: "/edges/bulk")

        let input = BulkEdgeInput(
            edges: [BulkEdgeInputItem(sourceId: "a", targetId: "b", edgeType: "about")],
            mode: .upsert, atomic: true, enableFanout: true
        )
        let emitted = try encodedKeys(input)
        #expect(emitted.isEmpty == false)
        let undeclared = emitted.subtracting(declared)
        #expect(undeclared.isEmpty, "the kit sends bulk-edges fields the route does not declare: \(undeclared.sorted())")
    }
}
