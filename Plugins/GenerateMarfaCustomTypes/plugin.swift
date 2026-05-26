import Foundation
import PackagePlugin

// SwiftPM command plugin — wraps `codegen-custom-types` for consumer ergonomics.
//
// Invocation (from the consuming package's root):
//   swift package --allow-writing-to-package-directory generate-marfa-custom-types
//   swift package --allow-writing-to-package-directory \
//                 --allow-network-connections all \
//                 generate-marfa-custom-types --sync
//
// Flags after the plugin name are passed through to the underlying tool.
// Pass `--sync` to run `sync-custom-types` first (which pulls schemas from
// the Marfa instance named in MARFA_API_URL / MARFA_API_KEY, writes the cache
// directory, then generates). Otherwise only codegen runs.

@main
struct GenerateMarfaCustomTypes: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var passthrough = arguments
        var runSync = false
        if let index = passthrough.firstIndex(of: "--sync") {
            runSync = true
            passthrough.remove(at: index)
        }

        if runSync {
            let sync = try context.tool(named: "sync-custom-types")
            try run(tool: sync.path.string, arguments: passthrough, workingDirectory: context.package.directory.string)
        } else {
            let codegen = try context.tool(named: "codegen-custom-types")
            try run(tool: codegen.path.string, arguments: passthrough, workingDirectory: context.package.directory.string)
        }
    }

    private func run(tool: String, arguments: [String], workingDirectory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("generate-marfa-custom-types exited with status \(process.terminationStatus)")
            throw PluginError.toolExitedNonZero(Int(process.terminationStatus))
        }
    }
}

enum PluginError: Error {
    case toolExitedNonZero(Int)
}
