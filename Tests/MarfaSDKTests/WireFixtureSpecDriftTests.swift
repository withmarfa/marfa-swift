import Testing
import Foundation
@testable import MarfaSDK

/// `WireRoundTripTests` proves a model can re-encode a fixture without losing
/// a key. It cannot prove the fixture carries every key the platform sends,
/// and for a hand-written model that is the gap that matters: a field added
/// upstream reaches neither the model nor the fixture, so the round-trip
/// stays green while the model silently erases the field on write.
///
/// That happened. `SpaceConfig` was missing two of the six fields the spec
/// declares, and a `PUT` of a decoded config dropped them.
///
/// So this reads the committed OpenAPI snapshot and asserts the fixture's key
/// set matches it exactly. Refreshing the snapshot then fails this test, which
/// fails until the fixture gains the field, which fails the round-trip until
/// the model gains it too. The chain ends at the model rather than at whoever
/// remembered.
///
/// Generated models need none of this: the freshness job regenerates them from
/// the same snapshot and diffs. Hand-written ones are what drift.
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

    /// Property names of an inline object schema, one level down.
    private func properties(of schema: Any?) throws -> Set<String> {
        let object = try #require(schema as? [String: Any], "expected an object schema")
        let properties = try #require(
            object["properties"] as? [String: Any], "schema declares no properties")
        return Set(properties.keys)
    }

    @Test("SpaceConfig")
    func spaceConfig() throws {
        let response = try #require(
            (((spec()["paths"] as? [String: Any])?["/spaces/me/config"]
                as? [String: Any])?["get"] as? [String: Any])
                .flatMap { $0["responses"] as? [String: Any] }
                .flatMap { $0["200"] as? [String: Any] }
                .flatMap { $0["content"] as? [String: Any] }
                .flatMap { $0["application/json"] as? [String: Any] }?["schema"],
            "GET /spaces/me/config declares no 200 response schema")

        let fixture = try fixture("space_config")

        #expect(
            Set(fixture.keys) == (try properties(of: response)),
            "space_config.json and the spec disagree on the top-level fields")

        let enforcementSchema = try #require(
            (response as? [String: Any])?["properties"] as? [String: Any])["enforcement"]
        #expect(
            Set((fixture["enforcement"] as? [String: Any] ?? [:]).keys)
                == (try properties(of: enforcementSchema)),
            "space_config.json and the spec disagree on the enforcement levers")
    }

    // `PaginatedResult` is the other hand-written model with a fixture, and it
    // is deliberately not checked here: it is generic over its element and the
    // spec inlines its shape at every paginated path rather than naming it
    // once, so there is no single schema to point at.
}
