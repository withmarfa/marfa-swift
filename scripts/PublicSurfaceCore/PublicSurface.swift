// Records the SDK's public surface and holds the changelog to it.
//
// `swift package dump-symbol-graph` knows every public declaration in the
// module. This distils that into a sorted text file, compares two of them, and
// reports what the changelog does not account for.
//
// Why a distilled text file rather than the symbol graph itself: the graph is
// six megabytes of doc comments and absolute source paths, so it is neither
// reviewable in a diff nor stable between machines. What matters for source
// compatibility is the set of public declarations, and that fits in a file a
// person can read.
//
// What this does NOT see, recorded here rather than left to be discovered:
// protocol conformances. Dropping a public conformance is source-breaking and
// lives in the graph's `relationships` rather than its `symbols`, where it is
// buried under synthesised `Sendable`, `Copyable` and `Equatable` entries.
// Separating declared conformances from synthesised ones is its own piece of
// work, and this check is silent on that class.

import Foundation

// MARK: - The surface

/// A key's public declarations.
///
/// The key is the declaration's path — `CreateItemInput.edges` — rather than
/// its mangled symbol name, because the path is what separates a removal from
/// a retype. Keyed on the mangled name, a property that changes type looks
/// like one symbol vanishing and an unrelated one arriving.
///
/// The value is a set rather than one string because overloads share a path:
/// `foo(bar:)` taking an `Int` and `foo(bar:)` taking a `String` are two
/// declarations at one key, and a change to either is a change to the key.
public struct SurfaceEntry: Equatable, Sendable {
    public var kind: String
    public var declarations: Set<String>

    public init(kind: String, declarations: Set<String>) {
        self.kind = kind
        self.declarations = declarations
    }
}

public typealias Surface = [String: SurfaceEntry]

public enum PublicSurfaceError: Error, Equatable, CustomStringConvertible {
    case unreadableSymbolGraph(String)
    case emptyBaseline(String)
    case emptyCurrent

    public var description: String {
        switch self {
        case .unreadableSymbolGraph(let detail):
            return "the symbol graph could not be read: \(detail)"
        case .emptyBaseline(let path):
            return """
                \(path) records no public declarations. It is truncated, or the \
                generator that wrote it is broken. Reading that as "nothing changed" \
                would let every break through, so this refuses instead. Regenerate it \
                with ./scripts/public-surface.sh.
                """
        case .emptyCurrent:
            return """
                the regenerated surface records no public declarations. The symbol-graph \
                extraction failed; comparing against it would report the whole SDK as \
                removed, or — if the baseline were also empty — as unchanged.
                """
        }
    }
}

// MARK: - Reading a symbol graph

/// Distils one module's symbol graph into the entries the snapshot records.
public func distil(symbolGraph data: Data) throws -> [(key: String, kind: String, declaration: String)] {
    guard
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let symbols = root["symbols"] as? [[String: Any]]
    else {
        throw PublicSurfaceError.unreadableSymbolGraph("no `symbols` array")
    }

    var entries: [(key: String, kind: String, declaration: String)] = []
    for symbol in symbols {
        // `--minimum-access-level public` is passed at extraction, so everything
        // here should already be public or open. Re-checking costs nothing and
        // means an extraction run without the flag writes a visibly wrong file
        // rather than a quietly wider one.
        let access = symbol["accessLevel"] as? String ?? ""
        guard access == "public" || access == "open" else { continue }

        guard
            let path = symbol["pathComponents"] as? [String], !path.isEmpty,
            let kindObject = symbol["kind"] as? [String: Any],
            let kind = kindObject["identifier"] as? String
        else { continue }

        let fragments = symbol["declarationFragments"] as? [[String: Any]] ?? []
        let declaration = normalise(fragments.compactMap { $0["spelling"] as? String }.joined())
        guard !declaration.isEmpty else { continue }

        entries.append(
            (
                key: path.joined(separator: "."),
                kind: kind.hasPrefix("swift.") ? String(kind.dropFirst("swift.".count)) : kind,
                declaration: declaration
            )
        )
    }
    return entries
}

/// Collapses the whitespace a multi-line declaration carries, so reformatting
/// a declaration in the source does not read as an API change.
public func normalise(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

public let snapshotHeader = """
    # The public surface of MarfaSDK, as of the last release.
    #
    # Generated by ./scripts/public-surface.sh — do not edit by hand.
    #
    # This file is the baseline the changelog is held to. CI regenerates the
    # surface at HEAD, compares it with this file, and refuses a change that the
    # `## [Unreleased]` section of CHANGELOG.md does not name.
    #
    # It is updated at a release cut, after Unreleased is renamed to the version
    # being cut, and never in between. Forgetting to update it does not go
    # unnoticed: the next change's check reports the last release's entries as
    # unaccounted for, because they are no longer in Unreleased.
    #
    # Columns are tab-separated: path, kind, declaration.

    """

/// Renders entries as the snapshot file's contents.
public func render(_ entries: [(key: String, kind: String, declaration: String)]) -> String {
    // Sorted so the file is a diff rather than a reshuffle. Two entries can
    // share a key, so the declaration breaks the tie.
    let sorted = entries.sorted { ($0.key, $0.declaration) < ($1.key, $1.declaration) }
    let body = sorted.map { "\($0.key)\t\($0.kind)\t\($0.declaration)" }.joined(separator: "\n")
    return snapshotHeader + body + "\n"
}

/// Reads a rendered snapshot back.
public func parseSurface(_ text: String) -> Surface {
    var surface: Surface = [:]
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if line.hasPrefix("#") { continue }
        let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard columns.count == 3 else { continue }
        let key = String(columns[0])
        var entry = surface[key] ?? SurfaceEntry(kind: String(columns[1]), declarations: [])
        entry.declarations.insert(String(columns[2]))
        surface[key] = entry
    }
    return surface
}

// MARK: - Comparing two surfaces

public struct SurfaceDiff: Equatable, Sendable {
    public var removed: [String]
    public var added: [String]
    public var changed: [String]

    public var isEmpty: Bool { removed.isEmpty && added.isEmpty && changed.isEmpty }
    public var count: Int { removed.count + added.count + changed.count }
}

/// Compares a baseline surface with the current one.
///
/// Throws rather than returning an empty diff when either side records nothing.
/// That is the permissive direction and the one worth guarding: two empty
/// surfaces compare equal, so a broken extraction would report "unchanged" and
/// wave every break through — which is precisely what this check exists to stop.
public func compare(baseline: Surface, current: Surface, baselinePath: String = "the baseline") throws -> SurfaceDiff {
    guard !baseline.isEmpty else { throw PublicSurfaceError.emptyBaseline(baselinePath) }
    guard !current.isEmpty else { throw PublicSurfaceError.emptyCurrent }

    var added = current.keys.filter { baseline[$0] == nil }
    var removed = baseline.keys.filter { current[$0] == nil }
    var changed = current.compactMap { key, entry -> String? in
        guard let was = baseline[key] else { return nil }
        return was.declarations == entry.declarations ? nil : key
    }

    // A type that arrives or leaves brings its members with it. Reporting each
    // member separately would ask the changelog to name twenty-six things when
    // one of them is the fact.
    added = rollUpToTopLevel(added)
    removed = rollUpToTopLevel(removed)

    // An enum case is reported as its enum. A closed enum gaining or losing a
    // case breaks an exhaustive switch, which is a property of the enum rather
    // than of any one case, and it is how a changelog describes it.
    (added, changed) = foldEnumCases(added, into: changed, ownerLivesIn: current, kinds: current)
    (removed, changed) = foldEnumCases(removed, into: changed, ownerLivesIn: current, kinds: baseline)

    return SurfaceDiff(
        removed: Array(Set(removed)).sorted(),
        added: Array(Set(added)).sorted(),
        changed: Array(Set(changed)).sorted()
    )
}

/// Drops any key whose top-level ancestor is itself in the list.
func rollUpToTopLevel(_ keys: [String]) -> [String] {
    let topLevel = Set(keys.filter { !$0.contains(".") })
    return keys.filter { key in
        guard let root = key.split(separator: ".").first, key.contains(".") else { return true }
        return !topLevel.contains(String(root))
    }
}

/// Replaces enum-case keys with their owning enum, reported as a change.
func foldEnumCases(
    _ keys: [String],
    into changed: [String],
    ownerLivesIn current: Surface,
    kinds: Surface
) -> ([String], [String]) {
    var remaining: [String] = []
    var folded = changed
    for key in keys {
        guard kinds[key]?.kind == "enum.case", let owner = parent(of: key) else {
            remaining.append(key)
            continue
        }
        // Only fold onto an owner that still exists. An enum removed whole is
        // already rolled up above, and folding onto a name nobody can reference
        // any more would ask the changelog to describe a case of a missing type.
        if current[owner] != nil {
            folded.append(owner)
        } else {
            remaining.append(key)
        }
    }
    return (remaining, folded)
}

func parent(of key: String) -> String? {
    guard let index = key.lastIndex(of: ".") else { return nil }
    return String(key[key.startIndex..<index])
}

// MARK: - Holding the changelog to it

public struct ChangelogSection: Sendable {
    public var text: String

    public init(text: String) { self.text = text }

    /// Whether the section names this declaration.
    ///
    /// Deliberately literal. A check that tried to understand prose would be
    /// wrong in both directions; this one asks whether the name a consumer
    /// would search for is on the page.
    public func mentions(_ key: String) -> Bool {
        let components = key.split(separator: ".").map(String.init)
        guard components.count > 1 else { return containsWord(components[0]) }

        let owner = components[components.count - 2]
        let leaf = String(components[components.count - 1].prefix(while: { $0 != "(" }))

        // An initialiser or a subscript is described in terms of its type —
        // "the memberwise initialiser gains a parameter" — so demanding the
        // spelling `Foo.init` would refuse changelog entries that are correct.
        if leaf == "init" || leaf == "subscript" { return containsWord(owner) }

        // `Foo.bar` is how this changelog already writes a member. Both names
        // separately is the fallback, for an entry that puts the type in a
        // heading and the member in the sentence below it.
        if text.contains("\(owner).\(leaf)") { return true }

        // The API is namespaced, so a method on `AuthNamespace` is reached and
        // written as `auth.me()` and the type name never appears anywhere a
        // consumer would see it. Demanding the type's spelling would refuse the
        // way every namespace method in this SDK is already documented.
        if owner.hasSuffix("Namespace") {
            let stem = String(owner.dropLast("Namespace".count))
            if let initial = stem.first {
                let called = initial.lowercased() + stem.dropFirst()
                if text.contains("\(called).\(leaf)") { return true }
            }
        }

        return containsWord(owner) && containsWord(leaf)
    }

    /// Whole-word rather than substring: `Item` must not be satisfied by
    /// `CreateItemInput` happening to appear somewhere in the section.
    private func containsWord(_ word: String) -> Bool {
        guard let pattern = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_])\(NSRegularExpression.escapedPattern(for: word))(?![A-Za-z0-9_])"
        ) else { return false }
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Extracts the `## [Unreleased]` section, and only that section.
///
/// Reading past the next `## ` heading is the permissive failure here: with the
/// whole file in hand, a symbol named in any past release reads as accounted
/// for, and the check silently stops working the moment the SDK is a few
/// versions old.
public func unreleasedSection(inChangelog text: String) -> ChangelogSection {
    var collecting = false
    var lines: [String] = []
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("## ") {
            if collecting { break }
            collecting = line.lowercased().contains("unreleased")
            continue
        }
        if collecting { lines.append(line) }
    }
    // No Unreleased section at all is not "nothing to say" — it is a changelog
    // that can account for nothing, so every difference stays unaccounted for.
    return ChangelogSection(text: lines.joined(separator: "\n"))
}

/// The differences the section does not name, in the order they are reported.
public func unaccounted(in diff: SurfaceDiff, against section: ChangelogSection) -> [(verdict: String, key: String)] {
    var result: [(verdict: String, key: String)] = []
    for key in diff.removed where !section.mentions(key) { result.append(("removed", key)) }
    for key in diff.changed where !section.mentions(key) { result.append(("changed", key)) }
    for key in diff.added where !section.mentions(key) { result.append(("added", key)) }
    return result
}
