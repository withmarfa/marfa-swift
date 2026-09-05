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
/// **What this cannot see**, stated in the same breath as what it delivers,
/// because a guard whose limits are only implied is a guard nobody can trust.
///
/// It checks **names and their position**, not types, not required-ness, and
/// not values. It reads the vendored snapshot, so it is only as current as the
/// last `sync-openapi.sh` — the `Spec drift` workflow is what says whether
/// that is current. It covers the inputs named below rather than every
/// encodable in the kit, and **each has to be constructed with every field
/// populated**, because a nil field emits nothing and an under-populated
/// fixture reports green over exactly the mismatch this exists to catch. That
/// caveat was written here first and then missed on the array elements, so it
/// is worth more than a sentence: the first version of this suite passed a
/// renamed `source_id` because the item it built left the field nil.
///
/// It stops at the schema's leaves. A `properties` map and an item's `edges`
/// map are declared fields whose contents are the caller's own keys, so
/// descending into them would report every user key as undeclared — a guard
/// that fails on correct input, which is the loudest way to become ignored.
///
/// It does not resolve `$ref`. None of the four operations it reads uses one
/// today, checked rather than assumed; a request body that gains one would go
/// quietly unwalked, and that is the shape to watch for when this stops
/// finding things.
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

    /// Every property path the spec declares on one operation's request body,
    /// as dotted paths rather than a flat set of names.
    ///
    /// **Paths rather than names, because a flat set loses position** — and a
    /// field emitted at the wrong level is exactly the failure this suite
    /// exists to catch. A top-level `source` is not the `filter.source` the
    /// route declares, and against a flat union it passes while the server
    /// ignores it, which is the silent shape all over again.
    ///
    /// **Array element schemas are walked**, because for `POST /items/bulk`
    /// the payload *is* the array: checking only the envelope leaves every
    /// item field unchecked, and those are most of the surface.
    ///
    /// `oneOf`, `anyOf` and `allOf` branches are unioned at the same path,
    /// since a field valid in any branch is a field the route accepts.
    private func declaredBodyPaths(_ spec: [String: Any], method: String, path: String) throws -> Set<String> {
        let paths = try #require(spec["paths"] as? [String: Any])
        let route = try #require(paths[path] as? [String: Any], "spec declares no \(path)")
        let operation = try #require(route[method] as? [String: Any], "spec declares no \(method) \(path)")
        let body = try #require(operation["requestBody"] as? [String: Any], "no request body on \(method) \(path)")
        let content = try #require(body["content"] as? [String: Any])
        let json = try #require(content["application/json"] as? [String: Any])
        let schema = try #require(json["schema"] as? [String: Any])

        var declared: Set<String> = []
        func walk(_ node: Any, prefix: String) {
            guard let object = node as? [String: Any] else { return }
            if let properties = object["properties"] as? [String: Any] {
                for (name, child) in properties {
                    let here = prefix.isEmpty ? name : "\(prefix).\(name)"
                    declared.insert(here)
                    walk(child, prefix: here)
                }
            }
            // An array's elements share their parent's path: `items[0].type`
            // and `items[1].type` are the same field to a schema.
            if let items = object["items"] { walk(items, prefix: prefix) }
            for key in ["oneOf", "anyOf", "allOf"] {
                for branch in object[key] as? [[String: Any]] ?? [] { walk(branch, prefix: prefix) }
            }
        }
        walk(schema, prefix: "")
        return declared
    }

    /// The paths an encodable actually puts on the wire, in the same shape.
    ///
    /// An array contributes its elements' paths under the array's own path,
    /// matching how a schema describes them. Only the first element is walked:
    /// every element of a homogeneous array has the same shape, and a test
    /// constructing two would be asserting about its own fixture.
    private func encodedPaths<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let root = try JSONSerialization.jsonObject(with: data)

        var emitted: Set<String> = []
        func walk(_ node: Any, prefix: String) {
            if let object = node as? [String: Any] {
                for (name, child) in object {
                    let here = prefix.isEmpty ? name : "\(prefix).\(name)"
                    emitted.insert(here)
                    walk(child, prefix: here)
                }
            } else if let array = node as? [Any], let first = array.first {
                walk(first, prefix: prefix)
            }
        }
        walk(root, prefix: "")
        return emitted
    }

    /// The declared paths that have declared children.
    ///
    /// **This is what stops the check walking into free-form data.** A type's
    /// `properties` map and an item's `edges` map are declared fields whose
    /// *contents* are the caller's own keys — `items.properties.body` is a
    /// person's note body, not a field the route names. Descending into them
    /// would report every user key as undeclared, which is a guard that fails
    /// on correct input: the loudest way to become ignored.
    ///
    /// So an emitted path is checkable only where its parent is a declared
    /// object that declares children. Below that line, the schema has stopped
    /// describing names and started describing a bag.
    private func declaredParents(_ declared: Set<String>) -> Set<String> {
        Set(declared.compactMap { path -> String? in
            guard let dot = path.lastIndex(of: ".") else { return nil }
            return String(path[path.startIndex..<dot])
        })
    }

    /// The emitted paths this check can speak about at all.
    private func checkable(_ emitted: Set<String>, against declared: Set<String>) -> Set<String> {
        let parents = declaredParents(declared)
        return emitted.filter { path in
            guard let dot = path.lastIndex(of: ".") else { return true }
            return parents.contains(String(path[path.startIndex..<dot]))
        }
    }

    /// The bracketed query families the spec cannot declare as fixed names.
    ///
    /// **Named rather than pattern-matched**, and that is the correction: a
    /// blanket "skip anything with a bracket" exempts a family nobody has
    /// reviewed, which is the opposite of covering it. A new family fails here
    /// and forces a decision, the way this repository's route-coverage maps
    /// already work.
    private static let bracketedQueryFamilies: Set<String> = ["edge", "backref"]

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

        // A bracketed parameter is checked against the named families rather
        // than skipped for having a bracket: an unknown family lands in
        // `undeclared` and fails, which is the point.
        let checkable = emitted.filter { name in
            guard let bracket = name.firstIndex(of: "[") else { return true }
            return !Self.bracketedQueryFamilies.contains(String(name[name.startIndex..<bracket]))
        }
        let undeclared = checkable.subtracting(declared)
        #expect(undeclared.isEmpty, "the kit sends query parameters GET /items does not declare: \(undeclared.sorted())")
    }

    // MARK: - Request bodies

    /// The one that would have caught `emit_events`.
    @Test("every bulk-action field is one POST /items/bulk-actions declares")
    func bulkActionFieldsMatchTheSpec() throws {
        let declared = try declaredBodyPaths(try spec(), method: "post", path: "/items/bulk-actions")

        let input = BulkActionInput.transition(
            filter: BulkActionFilter(
                type: "core.note", state: .active, source: "seed", tier: .library,
                tags: ["a"], timestampAfter: "2026-01-01T00:00:00Z",
                timestampBefore: "2026-12-31T00:00:00Z", filter: #"body eq "x""#
            ),
            state: .archived,
            options: BulkActionOptions(dryRun: true, maxItems: 10, enableFanout: true)
        )

        let emitted = try encodedPaths(input)
        #expect(emitted.isEmpty == false)
        let undeclared = checkable(emitted, against: declared).subtracting(declared)
        #expect(undeclared.isEmpty, "the kit sends bulk-action fields the route does not declare: \(undeclared.sorted())")
    }

    @Test("every bulk-items field is one POST /items/bulk declares")
    func bulkItemsFieldsMatchTheSpec() throws {
        let declared = try declaredBodyPaths(try spec(), method: "post", path: "/items/bulk")

        // Every field populated, including the array element's. A nil field
        // emits nothing, so an under-populated fixture asserts about a subset
        // and reports green over exactly the mismatch this suite is for — the
        // caveat this file states, missed here on the first pass.
        let input = BulkInput(
            items: [BulkItemInput(
                id: "01a0", type: "core.note", properties: ["body": .string("b")],
                state: .active, tier: .library, timestamp: "2026-01-01T00:00:00Z",
                source: "seed", sourceId: "s1", device: "d1", tags: ["a"],
                edges: ["core.about": ["x"]]
            )],
            mode: .upsert, atomic: true, enableFanout: true
        )
        let emitted = try encodedPaths(input)
        #expect(emitted.isEmpty == false)
        let undeclared = checkable(emitted, against: declared).subtracting(declared)
        #expect(undeclared.isEmpty, "the kit sends bulk-items fields the route does not declare: \(undeclared.sorted())")
    }

    @Test("every bulk-edges field is one POST /edges/bulk declares")
    func bulkEdgesFieldsMatchTheSpec() throws {
        let declared = try declaredBodyPaths(try spec(), method: "post", path: "/edges/bulk")

        let input = BulkEdgeInput(
            edges: [BulkEdgeInputItem(
                id: "01a1", sourceId: "a", targetId: "b", edgeType: "about",
                properties: ["weight": .int(1)]
            )],
            mode: .upsert, atomic: true, enableFanout: true
        )
        let emitted = try encodedPaths(input)
        #expect(emitted.isEmpty == false)
        let undeclared = checkable(emitted, against: declared).subtracting(declared)
        #expect(undeclared.isEmpty, "the kit sends bulk-edges fields the route does not declare: \(undeclared.sorted())")
    }
}
