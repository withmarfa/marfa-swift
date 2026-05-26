import Foundation
import Testing
@testable import MarfaCodegenCore

/// Runs the full generator against the fixture schemas and compares the
/// output against golden Swift files.
@Suite struct GoldenTests {

    // MARK: - Helpers

    var fixturesBase: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    func runGeneratorForAll() throws -> [String: String] {
        // Copy fixture schemas into an isolated temp dir so the generator
        // runs against a realistic layout: a config file at repo root, a
        // schemas directory, an output directory.
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codegen-golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let schemasSrc = fixturesBase.appendingPathComponent("schemas")
        let schemasDst = tmpRoot.appendingPathComponent("MarfaTypes")
        try FileManager.default.copyItem(at: schemasSrc, to: schemasDst)

        let outputDir = tmpRoot.appendingPathComponent("Generated")

        let config = CodegenConfig(
            schema: 1,
            source: SourceConfig(mode: .local, directory: "MarfaTypes"),
            output: OutputConfig(directory: "Generated", accessLevel: .public),
            types: nil
        )
        let generator = Generator(config: config, configDir: tmpRoot)
        _ = try generator.run()

        // Load generated files as strings
        let files = (try FileManager.default.contentsOfDirectory(
            at: outputDir, includingPropertiesForKeys: nil
        )).filter { $0.pathExtension == "swift" }
        var out: [String: String] = [:]
        for f in files {
            out[f.lastPathComponent] = try String(contentsOf: f, encoding: .utf8)
        }
        return out
    }

    // MARK: - Tests

    @Test func generatedOutputMatchesGoldenFiles() throws {
        let generated = try runGeneratorForAll()
        let expectedDir = fixturesBase.appendingPathComponent("expected")
        let expectedFiles = (try FileManager.default.contentsOfDirectory(
            at: expectedDir, includingPropertiesForKeys: nil
        )).filter { $0.pathExtension == "swift" }

        // Same set of files on both sides
        let generatedNames = Set(generated.keys)
        let expectedNames = Set(expectedFiles.map { $0.lastPathComponent })
        #expect(generatedNames == expectedNames,
                "generated: \(generatedNames.sorted())\nexpected: \(expectedNames.sorted())")

        // Byte-exact content
        for file in expectedFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            let expected = try String(contentsOf: file, encoding: .utf8)
            let actual = generated[name] ?? ""
            if expected != actual {
                // Produce a human-diff-friendly error.
                let mismatch = firstDifference(expected: expected, actual: actual)
                Issue.record("""
                golden mismatch for \(name):
                first diff at line \(mismatch.line):
                  expected: \(mismatch.expectedLine)
                  actual:   \(mismatch.actualLine)
                """)
            }
        }
    }

    // MARK: - Diff helpers

    struct Mismatch {
        let line: Int
        let expectedLine: String
        let actualLine: String
    }

    func firstDifference(expected: String, actual: String) -> Mismatch {
        let e = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let a = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let count = max(e.count, a.count)
        for i in 0..<count {
            let el = i < e.count ? String(e[i]) : "<EOF>"
            let al = i < a.count ? String(a[i]) : "<EOF>"
            if el != al {
                return Mismatch(line: i + 1, expectedLine: el, actualLine: al)
            }
        }
        return Mismatch(line: 0, expectedLine: "(files identical?)", actualLine: "(files identical?)")
    }
}
