import Testing
import Foundation

/// The domain-model generator prunes output that no longer corresponds to a
/// schema, which is right when a type is deleted upstream and wrong for every
/// other reason a schema might go missing from its input.
///
/// It used to skip a schema it could not decode, with a warning, and then let
/// the prune delete that type's model — so an unreadable file and a deleted
/// type produced the same result, and the run exited 0. That happened: the
/// platform relaxed the last required field on the three `core.file.*` media
/// types, the generator's schema decoder required the `required` key to be
/// present, and a sync removed `CoreFileImage`, `CoreFileVideo` and
/// `CoreFileAudio` from the SDK without failing.
///
/// The decoder is fixed and a parse failure is now fatal, but neither of those
/// is the property worth pinning. This is: whatever the generator's input
/// looks like, every non-deferred core schema in the vendored snapshot has a
/// model on the public surface. A future input the generator cannot read fails
/// here rather than quietly subtracting a type.
///
/// What this cannot see is a schema missing from the *snapshot*: nothing
/// here compares the snapshot with the monorepo.
@Suite("Every vendored core schema has a generated model")
struct DomainModelCoverageTests {

    /// The package root, walked up from this file, matching the approach in
    /// `SystemSchemaDriftTests`: the snapshot belongs to the codegen library's
    /// resource bundle rather than this target's, and the file the sync script
    /// writes is the one worth reading.
    private var packageRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    /// Mirrors `structName(for:)` in `codegen-domain.swift`. Duplicated rather
    /// than shared because that generator is an executable target with no
    /// importable surface; the mapping is four lines and changing it would
    /// fail here loudly.
    private func structName(for typeId: String) -> String {
        typeId
            .split(separator: ".")
            .flatMap { $0.split(separator: "_") }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
    }

    @Test("No core schema is missing its domain model")
    func everySchemaHasAModel() throws {
        let typesDir = packageRoot
            .appendingPathComponent("scripts/MarfaCodegenCore/core-types")
        let generatedDir = packageRoot
            .appendingPathComponent("Sources/MarfaSDK/DomainModels/Generated")

        let schemaFiles = try FileManager.default
            .contentsOfDirectory(at: typesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        // A snapshot that reads as empty would make every assertion below
        // vacuous, which is the same silent-pass shape this test exists for.
        #expect(schemaFiles.count > 0, "vendored core-type snapshot is empty")

        var expected: Set<String> = []
        for file in schemaFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data = try Data(contentsOf: file)
            let json = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any],
                "\(file.lastPathComponent) is not a JSON object"
            )
            if json["_deferred"] as? Bool == true { continue }
            let id = try #require(
                json["id"] as? String,
                "\(file.lastPathComponent) declares no id"
            )
            expected.insert("\(structName(for: id)).swift")
        }

        let generated = Set(
            try FileManager.default
                .contentsOfDirectory(at: generatedDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
                .map(\.lastPathComponent)
        )

        let missing = expected.subtracting(generated).sorted()
        #expect(
            missing.isEmpty,
            "vendored schemas with no generated model: \(missing.joined(separator: ", "))"
        )

        // The other direction: output with no schema behind it is a model the
        // prune should have removed and did not.
        let orphaned = generated.subtracting(expected).sorted()
        #expect(
            orphaned.isEmpty,
            "generated models with no vendored schema: \(orphaned.joined(separator: ", "))"
        )
    }
}
