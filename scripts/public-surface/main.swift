// Command-line face over PublicSurfaceCore. Everything with a decision in it
// lives in the library so it can be tested; this file reads arguments, reads
// and writes files, and chooses an exit code.
//
//   public-surface emit  <symbolgraph-dir> <out-path>
//   public-surface check <baseline-path> <current-path> <changelog-path>

import Foundation
import PublicSurfaceCore

let arguments = Array(CommandLine.arguments.dropFirst())

func usageFailure() -> Never {
    FileHandle.standardError.write(Data("""
        usage:
          public-surface emit  <symbolgraph-dir> <out-path>
          public-surface check <baseline-path> <current-path> <changelog-path>

        """.utf8))
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ public-surface: \(message)\n".utf8))
    exit(1)
}

switch arguments.first {
case "emit":
    guard arguments.count == 3 else { usageFailure() }
    // Only MarfaSDK. MarfaSDKTestSupport is a public product too, but AGENTS.md
    // states it carries no semver stability across SDK minor versions, so
    // holding a changelog entry against every change to it would demand records
    // the project has said it does not promise.
    let graph = URL(fileURLWithPath: arguments[1]).appendingPathComponent("MarfaSDK.symbols.json")
    guard let data = try? Data(contentsOf: graph) else {
        fail("no symbol graph at \(graph.path). Run ./scripts/public-surface.sh rather than this program directly.")
    }
    do {
        let entries = try distil(symbolGraph: data)
        guard !entries.isEmpty else {
            fail("\(graph.path) yielded no public declarations. The extraction ran but produced nothing, which would write a baseline that accepts anything.")
        }
        try render(entries).write(toFile: arguments[2], atomically: true, encoding: .utf8)
        print("  \(entries.count) public declarations → \(arguments[2])")
    } catch {
        fail("\(error)")
    }

case "check":
    guard arguments.count == 4 else { usageFailure() }
    let (baselinePath, currentPath, changelogPath) = (arguments[1], arguments[2], arguments[3])
    guard let baselineText = try? String(contentsOfFile: baselinePath, encoding: .utf8) else {
        fail("cannot read \(baselinePath).")
    }
    guard let currentText = try? String(contentsOfFile: currentPath, encoding: .utf8) else {
        fail("cannot read \(currentPath).")
    }
    guard let changelogText = try? String(contentsOfFile: changelogPath, encoding: .utf8) else {
        fail("cannot read \(changelogPath).")
    }

    let diff: SurfaceDiff
    do {
        diff = try compare(
            baseline: parseSurface(baselineText),
            current: parseSurface(currentText),
            baselinePath: baselinePath
        )
    } catch {
        fail("\(error)")
    }

    guard !diff.isEmpty else {
        print("  the public surface is unchanged since the last release")
        exit(0)
    }

    let noun = diff.count == 1 ? "declaration differs" : "declarations differ"
    print("  \(diff.count) public \(noun) from the last release (\(diff.removed.count) removed, \(diff.changed.count) changed, \(diff.added.count) added)")

    let missing = unaccounted(in: diff, against: unreleasedSection(inChangelog: changelogText))
    guard !missing.isEmpty else {
        print("  the Unreleased section names all of them")
        exit(0)
    }

    var message = "\n✗ CHANGELOG.md's Unreleased section does not account for the public surface:\n\n"
    for entry in missing {
        message += "    \(entry.verdict.padding(toLength: 7, withPad: " ", startingAt: 0))  \(entry.key)\n"
    }
    message += """

        A consumer reads the changelog, not the diff. Add an entry naming each
        one: a removal or a retype under `### Removed` or `### Changed`, a new
        public name under `### Added` — because a name this SDK adds may collide
        with one a consumer already invented for the same concept, and that is a
        build failure in a release described as safe to take.

        If the surface changed and you meant it to, that entry is the work. If it
        changed and you did not mean it to, that is the bug this found.

        The baseline is scripts/public-surface.txt, the surface as of the last
        release. It is regenerated at a release cut and not before, so anything
        listed above is something a consumer taking the next version will meet.

        """
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)

default:
    usageFailure()
}
