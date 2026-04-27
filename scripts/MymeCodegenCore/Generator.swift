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

        // 6. Pre-check: collision-free struct names. Also surface a soft
        //    warning if any custom id sits under a reserved namespace root
        //    (`core`, `system`, `app`, `user`, `myme`). Soft because the
        //    server is the authoritative validator at registration; this
        //    catches the most common author mistakes locally before a
        //    round-trip.
        Self.warnReservedRoots(emittableIDs)
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

    /// Reserved namespace roots per TSC42 §3. Authors registering custom
    /// types should claim their own publisher handle (`<publisher>.<type>`)
    /// or use `user.<type>` for unpublished personal types; `app.<name>.<type>`
    /// is reserved for registered apps. `core.*` is filtered out earlier;
    /// the others surface here as warnings.
    static let reservedNamespaceRoots: Set<String> = [
        "core", "system", "app", "user", "myme",
    ]

    /// Classify an id against the reserved-root rules. `nil` means the id
    /// looks fine; a non-nil string is a human-readable warning message.
    /// `app.<name>.<type>` is allowed (three-segment shape); two-segment
    /// `app.x` is malformed. `user.<type>` requires a non-empty second
    /// segment.
    public static func reservedRootWarning(for id: String) -> String? {
        let segments = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let root = segments.first, reservedNamespaceRoots.contains(root) else {
            return nil
        }
        switch root {
        case "core":
            // SchemaLoader rejects core.* with allowCoreTypes: false; should
            // never reach here. Belt-and-braces.
            return "type id \(id) uses reserved root `core`; only the platform may publish core.* types."
        case "system", "myme":
            return "type id \(id) uses reserved root `\(root)`; only the platform may publish \(root).* types. The server will reject this registration."
        case "app":
            if segments.count < 3 || segments[1].isEmpty || segments.dropFirst(2).joined(separator: ".").isEmpty {
                return "type id \(id) uses reserved root `app` but is missing the app-name or type segment. Expected shape app.<app-name>.<type>."
            }
            return nil
        case "user":
            if segments.count < 2 || segments[1].isEmpty {
                return "type id \(id) uses reserved root `user` but is missing the type segment. Expected shape user.<type>."
            }
            return nil
        default:
            return nil
        }
    }

    /// Emit a soft warning to stderr for each reserved-root violation.
    /// Doesn't abort — the server is authoritative.
    static func warnReservedRoots(_ ids: [String]) {
        for id in ids {
            if let warning = reservedRootWarning(for: id) {
                FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
            }
        }
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
