// codegen-custom-types — generates typed Swift domain-model structs for
// custom Myme types registered by the app.
//
// Usage (from the consuming app's repo root):
//   swift run codegen-custom-types [--config path/to/myme-codegen.json]
//
// Reads: myme-codegen.json (defaults to `<cwd>/myme-codegen.json`).
// Writes: <output.directory>/<StructName>.swift (one per custom type).
// Prunes any stray .swift files in the output directory whose name no
// longer matches a custom type ID.
//
// Freshness check (consuming app's CI):
//   swift run codegen-custom-types
//   git diff --exit-code -- <output.directory>

import Foundation
import MymeCodegenCore

func parseArgs() -> (configPath: String?, showHelp: Bool) {
    var configPath: String?
    var showHelp = false
    var i = 1
    let args = CommandLine.arguments
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--config", "-c":
            if i + 1 < args.count {
                configPath = args[i + 1]
                i += 2
            } else {
                FileHandle.standardError.write(Data("--config requires an argument\n".utf8))
                exit(2)
            }
        case "--help", "-h":
            showHelp = true
            i += 1
        default:
            FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
            exit(2)
        }
    }
    return (configPath, showHelp)
}

func printHelp() {
    print("""
    codegen-custom-types — generates Swift domain models for custom Myme types.

    Usage:
      swift run codegen-custom-types [options]

    Options:
      --config, -c <path>   Path to myme-codegen.json (default: ./myme-codegen.json)
      --help, -h            Show this help.

    See Sources/MymeSDK/DomainModels/Generated/CoreNote.swift in the SDK
    for the output shape.
    """)
}

let args = parseArgs()
if args.showHelp {
    printHelp()
    exit(0)
}

do {
    let (config, configDir) = try ConfigLoader.load(path: args.configPath)
    let generator = Generator(config: config, configDir: configDir)
    let result = try generator.run()

    print("generated \(result.generated.count) files")
    for url in result.generated {
        print("  + \(url.lastPathComponent)")
    }
    for url in result.pruned {
        print("  - \(url.lastPathComponent) (pruned)")
    }
    if !result.skipped.isEmpty {
        print("skipped \(result.skipped.count) filtered types: \(result.skipped.joined(separator: ", "))")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
