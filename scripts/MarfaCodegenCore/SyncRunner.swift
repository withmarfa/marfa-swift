import Foundation

public struct SyncError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A minimal HTTP fetch abstraction. `URLSession` is the production
/// implementation; tests can substitute an in-memory fetcher without
/// routing through URLProtocol.
public protocol HTTPFetcher: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionFetcher: HTTPFetcher {
    public init() {}
    public func get(url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError("invalid response from \(url.absoluteString)")
        }
        return (data, http)
    }
}

/// Pulls type schemas from a live Marfa instance into the config's cache
/// directory, prunes stale files, and (optionally) runs the generator.
public struct SyncRunner: Sendable {

    public struct Result: Sendable {
        public let written: [String]
        public let pruned: [URL]
        public let generated: Generator.Result?
    }

    public let config: CodegenConfig
    public let configDir: URL
    public let apiURL: URL
    public let apiKey: String
    public let fetcher: any HTTPFetcher
    public let runGenerate: Bool

    public init(
        config: CodegenConfig,
        configDir: URL,
        apiURL: URL,
        apiKey: String,
        fetcher: any HTTPFetcher = URLSessionFetcher(),
        runGenerate: Bool = true
    ) {
        self.config = config
        self.configDir = configDir
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.fetcher = fetcher
        self.runGenerate = runGenerate
    }

    public func run() async throws -> Result {
        guard config.source.mode == .live else {
            throw SyncError("sync requires source.mode=live (got \(config.source.mode.rawValue))")
        }
        guard let cacheDirRel = config.source.cacheDirectory else {
            throw SyncError("source.cacheDirectory is required for live sync")
        }
        let cacheDir = ConfigLoader.resolvePath(cacheDirRel, relativeTo: configDir)

        let typesURL = apiURL.appendingPathComponent("types")
        let (data, response) = try await fetcher.get(
            url: typesURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
            ]
        )
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw SyncError("GET /types returned HTTP \(response.statusCode): \(body)")
        }

        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SyncError("GET /types did not return a JSON array")
        }

        var byID: [String: [String: Any]] = [:]
        for dict in raw {
            guard let id = dict["id"] as? String else { continue }
            byID[id] = dict
        }
        let allIDs = Array(byID.keys).sorted()
        let kept = filterTypeIDs(allIDs, filters: config.types)
        let keptSet = Set(kept)

        try FileWriter.ensureDirectory(cacheDir)

        var written: [String] = []
        for id in kept.sorted() {
            let dict = byID[id]!
            let outURL = cacheDir.appendingPathComponent("\(id).json")
            let bytes = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try bytes.write(to: outURL, options: .atomic)
            written.append(id)
        }

        let existing = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" } ?? []
        var pruned: [URL] = []
        for file in existing {
            let id = file.deletingPathExtension().lastPathComponent
            if !keptSet.contains(id) {
                try? FileManager.default.removeItem(at: file)
                pruned.append(file)
            }
        }

        var genResult: Generator.Result?
        if runGenerate {
            // Flip to local-mode view of the freshly-synced cache directory.
            let localConfig = CodegenConfig(
                schema: config.schema,
                source: SourceConfig(mode: .local, directory: cacheDir.path),
                output: config.output,
                types: config.types
            )
            genResult = try Generator(config: localConfig, configDir: configDir).run()
        }

        return Result(written: written, pruned: pruned, generated: genResult)
    }
}
