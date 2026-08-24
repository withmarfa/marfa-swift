import Testing
import Foundation

/// `WireRoundTripTests` proves a model can re-encode a fixture without losing
/// a key. It cannot prove the fixture carries every key the platform sends,
/// and for a hand-written model that is the gap that matters: a field added
/// upstream reaches neither the model nor the fixture, so the round-trip
/// stays green while the model silently erases the field on write.
///
/// That happened. `SpaceConfig` was missing two of the six fields the spec
/// declares, and a `PUT` of a decoded config dropped them.
///
/// So this reads the committed OpenAPI snapshot and asserts the fixture's
/// field set matches it, at every depth. Refreshing the snapshot then fails
/// this test, which fails until the fixture gains the field, which fails the
/// round-trip until the model gains it too. The chain ends at the model
/// rather than at whoever remembered.
///
/// The walk is recursive on purpose. Checking only the top level and one
/// level down would leave the same bug reachable one level deeper: a key
/// added inside `enforcement.source_filter` would pass a shallow check, miss
/// the fixture, miss the model, and be erased on the next full-replacement
/// write.
///
/// Generated models need none of this: the freshness job regenerates them
/// from the same snapshot and diffs. Hand-written ones are what drift.
@Suite("Hand-written wire fixtures track the spec")
struct WireFixtureSpecDriftTests {

    /// The package root, walked up from this file. The snapshot is read from
    /// source rather than from a resource bundle: it is a codegen input, not
    /// a test resource, and this test wants the file `sync-openapi.sh` writes.
    private var packageRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    private func spec() throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("scripts/openapi.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Wire"),
            "fixture missing: Fixtures/Wire/\(name).json")
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Compare one object against its schema, then every nested object under
    /// it. `path` is carried for the failure message: a mismatch four levels
    /// down is useless without it.
    ///
    /// Only inline object schemas are walked. A `$ref`, a `oneOf` or an
    /// `additionalProperties` map has no single declared field set to compare
    /// against, so it is left alone rather than compared against a guess.
    /// Objects inside arrays are walked through the array's `items`.
    private func assertFields(
        _ value: Any?,
        against schema: Any?,
        path: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let schema = schema as? [String: Any] else { return }

        if let items = schema["items"], let elements = value as? [Any] {
            // An empty fixture array hides its element's field set from the
            // walk, which is this bug one level deeper. A fixture exists to
            // be compared, so an array whose elements have declared fields
            // has to carry one.
            if elements.isEmpty, (items as? [String: Any])?["properties"] != nil {
                Issue.record(
                    "\(path) is empty in the fixture, so the fields its elements declare are never compared",
                    sourceLocation: sourceLocation)
            }
            for (index, element) in elements.enumerated() {
                assertFields(
                    element, against: items, path: "\(path)[\(index)]",
                    sourceLocation: sourceLocation)
            }
            return
        }

        guard let properties = schema["properties"] as? [String: Any] else { return }
        guard let object = value as? [String: Any] else {
            Issue.record(
                "\(path) declares fields in the spec and the fixture has no object there",
                sourceLocation: sourceLocation)
            return
        }

        #expect(
            Set(object.keys) == Set(properties.keys),
            "\(path) and the spec disagree on which fields exist",
            sourceLocation: sourceLocation)

        for (key, childSchema) in properties where object[key] != nil {
            assertFields(
                object[key], against: childSchema, path: "\(path).\(key)",
                sourceLocation: sourceLocation)
        }
    }

    @Test("SpaceConfig")
    func spaceConfig() throws {
        let schema = try #require(
            (((spec()["paths"] as? [String: Any])?["/spaces/me/config"]
                as? [String: Any])?["get"] as? [String: Any])
                .flatMap { $0["responses"] as? [String: Any] }
                .flatMap { $0["200"] as? [String: Any] }
                .flatMap { $0["content"] as? [String: Any] }
                .flatMap { $0["application/json"] as? [String: Any] }?["schema"],
            "GET /spaces/me/config declares no 200 response schema")

        // The `#require` is the vacuity guard: a moved route fails the
        // schema lookup above, and a schema behind a `$ref` fails here,
        // rather than passing with nothing compared.
        let declared = try #require(
            (schema as? [String: Any])?["properties"] as? [String: Any],
            "the 200 schema declares no properties, so there is nothing to compare")
        // This is a ratchet on top of it, and a hand-maintained number. It
        // catches a fixture shrunk in step with a shrinking schema, which
        // the comparison below cannot see because both sides agree. A field
        // the platform genuinely removes fails here and the fix is editing
        // the six.
        #expect(declared.count >= 6, "the config schema lost fields rather than gaining them")

        assertFields(try fixture("space_config"), against: schema, path: "space_config")
    }

    // `PaginatedResult` is the other hand-written model with a fixture, and it
    // is deliberately not checked here: it is generic over its element and the
    // spec inlines its shape at every paginated path rather than naming it
    // once, so there is no single schema to point at.
}
