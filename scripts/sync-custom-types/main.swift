// sync-custom-types — fetches custom Marfa type schemas from a live instance
// and writes them to the local JSON cache directory, pruning stale files.
// Optionally triggers codegen-custom-types afterwards.
//
// Usage (from the consuming app's repo root):
//   swift run sync-custom-types [--config path/to/marfa-codegen.json] [--no-generate]
//
// Reads: marfa-codegen.json, MARFA_API_URL (env), MARFA_API_KEY (env).
// Writes: <source.cacheDirectory>/<type.id>.json (one per custom type).
// Prunes: stale <*.json> files in the cache directory.

import Foundation
import MarfaCodegenCore

struct SyncArgs {
    var configPath: String?
    var runGenerate: Bool = true
    var showHelp: Bool = false
}

func parseArgs() -> SyncArgs {
    var out = SyncArgs()
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        switch args[i] {
        case "--config", "-c":
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("--config requires an argument\n".utf8))
                exit(2)
            }
            out.configPath = args[i + 1]
            i += 2
        case "--no-generate":
            out.runGenerate = false
            i += 1
        case "--help", "-h":
            out.showHelp = true
            i += 1
        default:
            FileHandle.standardError.write(Data("unknown argument: \(args[i])\n".utf8))
            exit(2)
        }
    }
    return out
}

func printHelp() {
    print("""
    sync-custom-types — fetches custom Marfa type schemas from a live instance.

    Usage:
      swift run sync-custom-types [options]

    Options:
      --config, -c <path>   Path to marfa-codegen.json (default: ./marfa-codegen.json)
      --no-generate         Skip running codegen-custom-types afterwards.
      --help, -h            Show this help.

    Environment:
      MARFA_API_URL          Base URL of the Marfa instance (required).
      MARFA_API_KEY          API key with list-types permission (required).
    """)
}

@main
struct SyncCustomTypes {
    static func main() async {
        let args = parseArgs()
        if args.showHelp {
            printHelp()
            exit(0)
        }

        do {
            try await run(args: args)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(args: SyncArgs) async throws {
        let (config, configDir) = try ConfigLoader.load(path: args.configPath)

        let env = ProcessInfo.processInfo.environment
        guard let apiURLString = env["MARFA_API_URL"], let apiURL = URL(string: apiURLString) else {
            throw SyncError("MARFA_API_URL is not set or not a valid URL")
        }
        guard let apiKey = env["MARFA_API_KEY"], !apiKey.isEmpty else {
            throw SyncError("MARFA_API_KEY is not set")
        }

        let runner = SyncRunner(
            config: config,
            configDir: configDir,
            apiURL: apiURL,
            apiKey: apiKey,
            runGenerate: args.runGenerate
        )
        let result = try await runner.run()

        print("sync: wrote \(result.written.count) schemas")
        for id in result.written.sorted() { print("  + \(id)") }
        for url in result.pruned { print("  - \(url.lastPathComponent) (pruned)") }
        if let g = result.generated {
            print("generate: \(g.generated.count) files, \(g.pruned.count) pruned")
        }
    }
}
