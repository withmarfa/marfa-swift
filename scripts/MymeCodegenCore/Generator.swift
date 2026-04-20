import Foundation

/// Top-level orchestrator — loads schemas, applies filters, resolves
/// inheritance, emits Swift files, and prunes stale output.
public struct Generator: Sendable {

    public struct Result: Sendable {
        public let generated: [URL]
        public let pruned: [URL]
        public let skipped: [String]
    }

    public let config: CodegenConfig
    public let configDir: URL

    public init(config: CodegenConfig, configDir: URL) {
        self.config = config
        self.configDir = configDir
    }

    public func run() throws -> Result {
        // 1. Resolve source + output directories to absolute URLs.
        guard let sourceDirRel = config.source.resolvedDirectory else {
            throw ConfigLoaderError.missingField("source.directory or source.cacheDirectory")
        }
        let sourceDir = ConfigLoader.resolvePath(sourceDirRel, relativeTo: configDir)
        let outputDir = ConfigLoader.resolvePath(config.output.directory, relativeTo: configDir)

        // 2. Load custom schemas from user directory, rejecting any core.* id.
        let customSchemas = try SchemaLoader.loadSchemas(from: sourceDir, allowCoreTypes: false)

        // 3. Load bundled core types (used only as a parent-resolution registry).
        let coreSchemas = try SchemaLoader.loadBundledCoreTypes()

        // 4. Combined registry for parent-chain resolution. Custom types
        //    cannot redefine core ids (SchemaLoader already guards that).
        var registry = coreSchemas
        for (k, v) in customSchemas { registry[k] = v }

        // 5. Filter custom ids via include/exclude. `core.*` is always excluded.
        let customIDs = Array(customSchemas.keys).sorted()
        let emittableIDs = filterTypeIDs(customIDs, filters: config.types)
        let skipped = Set(customIDs).subtracting(emittableIDs).sorted()

        // 6. Pre-check: collision-free struct names.
        let nameMap = try NameMapper.buildNameMap(for: emittableIDs)

        // 7. Resolve + emit.
        try FileWriter.ensureDirectory(outputDir)
        var generated: [URL] = []
        var expectedNames = Set<String>()
        for id in emittableIDs.sorted() {
            let schema = customSchemas[id]!
            let resolved = try SchemaResolver.resolve(schema: schema, registry: registry)
            let structName = nameMap[id]!
            expectedNames.insert(structName)

            let relativeSource = sourceRelativePath(
                schemaID: id, sourceDir: sourceDir, configDir: configDir
            )
            let emitter = CodeEmitter(
                access: config.output.accessLevel,
                generatedHeader: config.output.generatedHeader,
                structName: structName
            )
            let code = emitter.emit(resolved: resolved, sourceRelativePath: relativeSource)
            let url = try FileWriter.write(content: code, to: outputDir, name: structName)
            generated.append(url)
        }

        // 8. Prune stale files.
        let pruned = FileWriter.prune(outputDir: outputDir, keeping: expectedNames)

        return Result(generated: generated, pruned: pruned, skipped: skipped)
    }

    // Best-effort "Source:" header path — relative to the config dir if we
    // can work that out; otherwise the raw filename we found on disk.
    private func sourceRelativePath(
        schemaID: String,
        sourceDir: URL,
        configDir: URL
    ) -> String {
        let filename = "\(schemaID).json"
        let full = sourceDir.appendingPathComponent(filename)
        let configPath = configDir.standardizedFileURL.path
        let fullPath = full.standardizedFileURL.path
        if fullPath.hasPrefix(configPath + "/") {
            return String(fullPath.dropFirst(configPath.count + 1))
        }
        return filename
    }
}
