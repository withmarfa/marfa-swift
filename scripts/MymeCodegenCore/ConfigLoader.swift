import Foundation

// MARK: - Config shape

public struct CodegenConfig: Codable, Sendable, Equatable {
    public let schema: Int
    public let source: SourceConfig
    public let output: OutputConfig
    public let types: TypeFilters?

    public init(
        schema: Int,
        source: SourceConfig,
        output: OutputConfig,
        types: TypeFilters? = nil
    ) {
        self.schema = schema
        self.source = source
        self.output = output
        self.types = types
    }
}

public struct SourceConfig: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case local, live }

    public let mode: Mode
    public let directory: String?
    public let cacheDirectory: String?

    public init(mode: Mode, directory: String? = nil, cacheDirectory: String? = nil) {
        self.mode = mode
        self.directory = directory
        self.cacheDirectory = cacheDirectory
    }

    /// Returns the directory schemas live in on disk, regardless of mode.
    public var resolvedDirectory: String? {
        switch mode {
        case .local: return directory
        case .live: return cacheDirectory
        }
    }
}

public struct OutputConfig: Codable, Sendable, Equatable {
    public enum AccessLevel: String, Codable, Sendable { case `public`, `internal` }

    public let directory: String
    public let accessLevel: AccessLevel
    public let generatedHeader: String?

    public init(
        directory: String,
        accessLevel: AccessLevel = .public,
        generatedHeader: String? = nil
    ) {
        self.directory = directory
        self.accessLevel = accessLevel
        self.generatedHeader = generatedHeader
    }

    enum CodingKeys: String, CodingKey {
        case directory, accessLevel, generatedHeader
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.directory = try c.decode(String.self, forKey: .directory)
        self.accessLevel = try c.decodeIfPresent(AccessLevel.self, forKey: .accessLevel) ?? .public
        self.generatedHeader = try c.decodeIfPresent(String.self, forKey: .generatedHeader)
    }
}

public struct TypeFilters: Codable, Sendable, Equatable {
    public let include: [String]?
    public let exclude: [String]?

    public init(include: [String]? = nil, exclude: [String]? = nil) {
        self.include = include
        self.exclude = exclude
    }
}

// MARK: - Loader

public enum ConfigLoaderError: Error, CustomStringConvertible {
    case fileNotFound(URL)
    case malformedJSON(URL, Error)
    case unsupportedSchema(Int)
    case missingField(String)
    case invalidMode(String)

    public var description: String {
        switch self {
        case .fileNotFound(let url):
            return "config file not found: \(url.path)"
        case .malformedJSON(let url, let error):
            return "config file at \(url.path) is not valid JSON: \(error)"
        case .unsupportedSchema(let v):
            return "unsupported config `schema` version: \(v). This tool supports schema version 1."
        case .missingField(let name):
            return "config is missing required field `\(name)`."
        case .invalidMode(let mode):
            return "config `source.mode` must be `local` or `live` (got `\(mode)`)."
        }
    }
}

public enum ConfigLoader {

    /// Canonical config filenames the loader searches for if none is passed.
    public static let defaultFilenames = ["myme-codegen.json", ".myme-codegen.json"]

    /// Loads and validates a config from `path`. `path` may be absolute or
    /// relative to `cwd`. Returns the parsed config and the resolved repo-root
    /// (parent directory of the config file).
    public static func load(
        path: String? = nil,
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> (config: CodegenConfig, configDir: URL) {

        let configURL: URL
        if let path {
            if (path as NSString).isAbsolutePath {
                configURL = URL(fileURLWithPath: path)
            } else {
                configURL = cwd.appendingPathComponent(path)
            }
        } else {
            var found: URL?
            for name in defaultFilenames {
                let candidate = cwd.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    found = candidate
                    break
                }
            }
            guard let f = found else {
                throw ConfigLoaderError.fileNotFound(
                    cwd.appendingPathComponent(defaultFilenames[0])
                )
            }
            configURL = f
        }

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ConfigLoaderError.fileNotFound(configURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw ConfigLoaderError.fileNotFound(configURL)
        }

        let config: CodegenConfig
        do {
            config = try JSONDecoder().decode(CodegenConfig.self, from: data)
        } catch {
            throw ConfigLoaderError.malformedJSON(configURL, error)
        }

        // Schema version
        guard config.schema == 1 else {
            throw ConfigLoaderError.unsupportedSchema(config.schema)
        }
        // Mode-specific required fields
        switch config.source.mode {
        case .local:
            guard config.source.directory != nil else {
                throw ConfigLoaderError.missingField("source.directory (required for mode=local)")
            }
        case .live:
            guard config.source.cacheDirectory != nil else {
                throw ConfigLoaderError.missingField("source.cacheDirectory (required for mode=live)")
            }
        }
        // Output dir
        guard !config.output.directory.isEmpty else {
            throw ConfigLoaderError.missingField("output.directory")
        }

        return (config, configURL.deletingLastPathComponent())
    }

    /// Resolves a config-relative path to an absolute URL.
    public static func resolvePath(_ path: String, relativeTo base: URL) -> URL {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path)
        }
        return base.appendingPathComponent(path)
    }
}

// MARK: - Glob matcher

/// Lightweight glob matcher supporting `*` (any chars within a segment) and
/// `**` (any number of segments). Segments separated by `.`.
///
/// Examples:
/// - `myapp.*` matches `myapp.booking`, `myapp.user` (one segment after)
/// - `myapp.**` matches any number of segments under `myapp`
/// - `*` matches a single top-level segment
public struct TypeIDMatcher: Sendable {
    public let pattern: String

    public init(_ pattern: String) {
        self.pattern = pattern
    }

    public func matches(_ id: String) -> Bool {
        let patternParts = pattern.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let idParts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return matchSegments(patternParts, idParts)
    }

    private func matchSegments(_ pattern: [String], _ input: [String]) -> Bool {
        var pi = 0
        var ii = 0
        while pi < pattern.count {
            let p = pattern[pi]
            if p == "**" {
                // Match zero or more segments greedily.
                if pi == pattern.count - 1 { return true }
                // Try every possible consumption.
                let rest = Array(pattern[(pi + 1)...])
                for take in 0...(input.count - ii) {
                    let remaining = Array(input[(ii + take)...])
                    if matchSegments(rest, remaining) { return true }
                }
                return false
            }
            if ii >= input.count { return false }
            let i = input[ii]
            if !matchSegment(pattern: p, input: i) { return false }
            pi += 1
            ii += 1
        }
        return ii == input.count
    }

    private func matchSegment(pattern: String, input: String) -> Bool {
        // Segment-level wildcard: `*` matches anything.
        if pattern == "*" { return true }
        // No wildcards inside a segment — exact match.
        if !pattern.contains("*") { return pattern == input }
        // `*` inside a segment — match against regex.
        var regex = "^"
        for ch in pattern {
            if ch == "*" { regex += ".*" }
            else { regex += NSRegularExpression.escapedPattern(for: String(ch)) }
        }
        regex += "$"
        return input.range(of: regex, options: .regularExpression) != nil
    }
}

/// Applies include/exclude filters to a list of type IDs.
public func filterTypeIDs(_ ids: [String], filters: TypeFilters?) -> [String] {
    // Hard rule — `core.*` is always excluded regardless of config, so a
    // misconfigured include glob cannot clobber SDK-shipped files.
    let isCore: (String) -> Bool = { $0.hasPrefix("core.") || $0 == "core" }

    let includeMatchers = (filters?.include ?? []).map { TypeIDMatcher($0) }
    let excludeMatchers = (filters?.exclude ?? []).map { TypeIDMatcher($0) }

    return ids.filter { id in
        if isCore(id) { return false }
        let included = includeMatchers.isEmpty || includeMatchers.contains { $0.matches(id) }
        let excluded = excludeMatchers.contains { $0.matches(id) }
        return included && !excluded
    }
}
