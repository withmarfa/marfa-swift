import Foundation
import Testing
@testable import MarfaCodegenCore

@Suite struct ConfigLoaderTests {

    // MARK: - Helpers

    func withTempConfig(_ json: String, _ body: (URL) throws -> Void) rethrows {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codegen-config-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configURL = tmp.appendingPathComponent("marfa-codegen.json")
        try? json.write(to: configURL, atomically: true, encoding: .utf8)
        try body(tmp)
    }

    // MARK: - Basic parsing

    @Test func loadsLocalModeConfig() throws {
        try withTempConfig(#"""
        {
          "schema": 1,
          "source": { "mode": "local", "directory": "MarfaTypes" },
          "output": { "directory": "Sources/Generated", "accessLevel": "public" }
        }
        """#) { dir in
            let (config, configDir) = try ConfigLoader.load(cwd: dir)
            #expect(config.schema == 1)
            #expect(config.source.mode == .local)
            #expect(config.source.directory == "MarfaTypes")
            #expect(config.output.directory == "Sources/Generated")
            #expect(config.output.accessLevel == .public)
            #expect(configDir.standardizedFileURL.path == dir.standardizedFileURL.path)
        }
    }

    @Test func loadsLiveModeConfig() throws {
        try withTempConfig(#"""
        {
          "schema": 1,
          "source": { "mode": "live", "cacheDirectory": ".marfa-types" },
          "output": { "directory": "Sources/Generated" }
        }
        """#) { dir in
            let (config, _) = try ConfigLoader.load(cwd: dir)
            #expect(config.source.mode == .live)
            #expect(config.source.cacheDirectory == ".marfa-types")
            #expect(config.output.accessLevel == .public, "default access level should be public")
        }
    }

    @Test func loadsInternalAccessLevel() throws {
        try withTempConfig(#"""
        {
          "schema": 1,
          "source": { "mode": "local", "directory": "MarfaTypes" },
          "output": { "directory": "Sources/Generated", "accessLevel": "internal" }
        }
        """#) { dir in
            let (config, _) = try ConfigLoader.load(cwd: dir)
            #expect(config.output.accessLevel == .internal)
        }
    }

    // MARK: - Validation

    @Test func unsupportedSchemaVersionThrows() {
        #expect {
            try withTempConfig(#"""
            {
              "schema": 2,
              "source": { "mode": "local", "directory": "x" },
              "output": { "directory": "y" }
            }
            """#) { dir in
                _ = try ConfigLoader.load(cwd: dir)
            }
        } throws: { error in
            if case ConfigLoaderError.unsupportedSchema(let v) = error { return v == 2 }
            return false
        }
    }

    @Test func localModeWithoutDirectoryThrows() {
        #expect {
            try withTempConfig(#"""
            {
              "schema": 1,
              "source": { "mode": "local" },
              "output": { "directory": "y" }
            }
            """#) { dir in
                _ = try ConfigLoader.load(cwd: dir)
            }
        } throws: { error in
            if case ConfigLoaderError.missingField = error { return true }
            return false
        }
    }

    @Test func missingConfigFileThrows() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codegen-config-missing-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect {
            _ = try ConfigLoader.load(cwd: tmp)
        } throws: { error in
            if case ConfigLoaderError.fileNotFound = error { return true }
            return false
        }
    }
}

// MARK: - Filter tests

@Suite struct FilterTests {

    @Test func defaultFilterDropsCoreTypes() {
        let ids = ["core.note", "myapp.booking", "myapp.user"]
        let kept = filterTypeIDs(ids, filters: nil)
        #expect(kept == ["myapp.booking", "myapp.user"])
    }

    @Test func includeGlobRestrictsToNamespace() {
        let ids = ["myapp.booking", "myapp.user", "other.thing"]
        let kept = filterTypeIDs(ids, filters: TypeFilters(include: ["myapp.*"], exclude: nil))
        #expect(kept == ["myapp.booking", "myapp.user"])
    }

    @Test func excludeGlobDropsMatches() {
        let ids = ["myapp.booking", "myapp.internal.debug", "myapp.internal.trace"]
        let kept = filterTypeIDs(
            ids,
            filters: TypeFilters(include: nil, exclude: ["myapp.internal.**"])
        )
        #expect(kept == ["myapp.booking"])
    }

    @Test func doubleStarMatchesDeepNesting() {
        let matcher = TypeIDMatcher("myapp.**")
        #expect(matcher.matches("myapp.booking"))
        #expect(matcher.matches("myapp.booking.reservation"))
        #expect(matcher.matches("myapp.a.b.c.d.e"))
        #expect(!matcher.matches("other.thing"))
    }

    @Test func singleStarMatchesOneSegment() {
        let matcher = TypeIDMatcher("myapp.*")
        #expect(matcher.matches("myapp.booking"))
        #expect(!matcher.matches("myapp.booking.reservation"))
    }

    @Test func coreIDsAlwaysDroppedEvenIfIncluded() {
        // Even if misconfigured to include core.*, the hard rule wins.
        let kept = filterTypeIDs(
            ["core.note", "myapp.booking"],
            filters: TypeFilters(include: ["core.*", "myapp.*"], exclude: nil)
        )
        #expect(kept == ["myapp.booking"])
    }
}
