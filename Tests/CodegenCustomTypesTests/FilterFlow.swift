// End-to-end flow tests that hit Generator.run() against temp dirs with
// various filter configs. Cover things GoldenTests doesn't: filtering,
// pruning, include/exclude behaviour, and config-driven access levels.

import Foundation
import Testing
@testable import MarfaCodegenCore

@Suite struct FilterFlowTests {

    func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codegen-flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func writeSchema(
        id: String,
        fields: [String: [String: Any]] = ["body": ["type": "string"]],
        parent: String? = nil,
        required: [String] = [],
        to dir: URL
    ) throws {
        var payload: [String: Any] = [
            "id": id,
            "version": 1,
            "fields": fields,
            "required": required,
        ]
        if let parent { payload["parent"] = parent }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    @Test func excludeGlobDropsMatches() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let schemasDir = root.appendingPathComponent("MarfaTypes")
        try writeSchema(id: "myapp.keep", to: schemasDir)
        try writeSchema(id: "myapp.internal.debug", to: schemasDir)

        let config = CodegenConfig(
            schema: 1,
            source: SourceConfig(mode: .local, directory: "MarfaTypes"),
            output: OutputConfig(directory: "Generated", accessLevel: .public),
            types: TypeFilters(include: nil, exclude: ["myapp.internal.**"])
        )
        let result = try Generator(config: config, configDir: root).run()
        let names = result.generated.map { $0.lastPathComponent }.sorted()
        #expect(names == ["MyappKeep.swift"])
        #expect(result.skipped == ["myapp.internal.debug"])
    }

    @Test func pruningRemovesStaleOutput() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let schemasDir = root.appendingPathComponent("MarfaTypes")
        let outDir = root.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        try writeSchema(id: "myapp.alpha", to: schemasDir)
        // Drop a stale Swift file masquerading as a prior generation
        try "// stale\n".write(
            to: outDir.appendingPathComponent("MyappGhost.swift"),
            atomically: true, encoding: .utf8
        )

        let config = CodegenConfig(
            schema: 1,
            source: SourceConfig(mode: .local, directory: "MarfaTypes"),
            output: OutputConfig(directory: "Generated", accessLevel: .public),
            types: nil
        )
        let result = try Generator(config: config, configDir: root).run()
        let names = result.generated.map { $0.lastPathComponent }
        #expect(names == ["MyappAlpha.swift"])
        #expect(result.pruned.map { $0.lastPathComponent } == ["MyappGhost.swift"])
        #expect(!FileManager.default.fileExists(atPath: outDir.appendingPathComponent("MyappGhost.swift").path))
    }

    @Test func coreTypeInSourceDirectoryFailsFast() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let schemasDir = root.appendingPathComponent("MarfaTypes")
        try writeSchema(id: "core.note", to: schemasDir)

        let config = CodegenConfig(
            schema: 1,
            source: SourceConfig(mode: .local, directory: "MarfaTypes"),
            output: OutputConfig(directory: "Generated", accessLevel: .public),
            types: nil
        )
        #expect {
            _ = try Generator(config: config, configDir: root).run()
        } throws: { error in
            if case SchemaLoaderError.coreTypeInCustomDirectory = error { return true }
            return false
        }
    }

    @Test func internalAccessLevelEmitsInternal() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let schemasDir = root.appendingPathComponent("MarfaTypes")
        try writeSchema(
            id: "myapp.internal_access",
            fields: ["x": ["type": "string"]],
            to: schemasDir
        )

        let config = CodegenConfig(
            schema: 1,
            source: SourceConfig(mode: .local, directory: "MarfaTypes"),
            output: OutputConfig(directory: "Generated", accessLevel: .internal),
            types: nil
        )
        let result = try Generator(config: config, configDir: root).run()
        #expect(result.generated.count == 1)
        let swift = try String(contentsOf: result.generated[0], encoding: .utf8)
        #expect(swift.contains("internal struct MyappInternalAccess"))
        #expect(!swift.contains("public struct MyappInternalAccess"))
    }

    @Test func parentInCoreRegistryResolves() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let schemasDir = root.appendingPathComponent("MarfaTypes")
        // This schema references `core.note` which comes from the bundled
        // registry — verifies the bundled core-types resource is loadable.
        try writeSchema(
            id: "myapp.extended_note",
            fields: ["priority": ["type": "integer"]],
            parent: "core.note",
            to: schemasDir
        )

        let config = CodegenConfig(
            schema: 1,
            source: SourceConfig(mode: .local, directory: "MarfaTypes"),
            output: OutputConfig(directory: "Generated", accessLevel: .public),
            types: nil
        )
        let result = try Generator(config: config, configDir: root).run()
        #expect(result.generated.count == 1)
        let swift = try String(contentsOf: result.generated[0], encoding: .utf8)
        // Has both own field and parent body/title
        #expect(swift.contains("Inherited from core.note"))
        #expect(swift.contains("public var priority"))
        #expect(swift.contains("public var body:"))
        #expect(swift.contains("public var title:"))
    }

    @Test func missingParentFailsFast() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let schemasDir = root.appendingPathComponent("MarfaTypes")
        try writeSchema(
            id: "myapp.orphan",
            fields: ["x": ["type": "string"]],
            parent: "nowhere.nothing",
            to: schemasDir
        )
        let config = CodegenConfig(
            schema: 1,
            source: SourceConfig(mode: .local, directory: "MarfaTypes"),
            output: OutputConfig(directory: "Generated", accessLevel: .public),
            types: nil
        )
        #expect {
            _ = try Generator(config: config, configDir: root).run()
        } throws: { error in
            if case SchemaResolverError.missingParent = error { return true }
            return false
        }
    }
}
