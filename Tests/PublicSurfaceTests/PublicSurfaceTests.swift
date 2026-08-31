// The surface lock's own tests.
//
// Weighted towards the permissive direction. A check like this fails safe in
// only one direction on its own: a bug that reports too much is noticed the
// first time somebody reads the output, and a bug that reports too little is
// noticed at a release that broke a consumer. So most of what follows pins a
// case where a plausible mistake would make the check accept anything.

import Foundation
import Testing
@testable import PublicSurfaceCore

@Suite struct SurfaceDistillationTests {

    /// A minimal symbol graph, in the shape `swift package dump-symbol-graph`
    /// writes one.
    func graph(_ symbols: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["symbols": symbols])
    }

    func symbol(
        path: [String],
        kind: String,
        declaration: String,
        access: String = "public"
    ) -> [String: Any] {
        [
            "accessLevel": access,
            "pathComponents": path,
            "kind": ["identifier": kind],
            "declarationFragments": declaration.map { ["spelling": String($0)] },
        ]
    }

    @Test func distilsPathKindAndDeclaration() throws {
        let entries = try distil(symbolGraph: graph([
            symbol(path: ["CreateItemInput", "edges"], kind: "swift.property", declaration: "var edges: [String]?")
        ]))
        #expect(entries.count == 1)
        #expect(entries[0].key == "CreateItemInput.edges")
        #expect(entries[0].kind == "property")
        #expect(entries[0].declaration == "var edges: [String]?")
    }

    /// The extraction is asked for public symbols only, but a run that forgot
    /// the flag would otherwise widen the baseline silently — and a wider
    /// baseline is a check that accepts internal churn as public change and
    /// then gets switched off for noise.
    @Test func internalSymbolsAreNotSurface() throws {
        let entries = try distil(symbolGraph: graph([
            symbol(path: ["Hidden"], kind: "swift.struct", declaration: "struct Hidden", access: "internal")
        ]))
        #expect(entries.isEmpty)
    }

    @Test func aBrokenGraphThrowsRatherThanReadingAsEmpty() {
        #expect(throws: PublicSurfaceError.self) {
            _ = try distil(symbolGraph: Data("not a symbol graph".utf8))
        }
    }

    /// Reformatting a declaration across lines is not an API change, and a
    /// snapshot that thought it was would redden on every source tidy-up.
    @Test func whitespaceInADeclarationIsNormalised() throws {
        let entries = try distil(symbolGraph: graph([
            symbol(path: ["f(a:)"], kind: "swift.func", declaration: "func f(\n    a: Int\n)")
        ]))
        #expect(entries[0].declaration == "func f( a: Int )")
    }

    @Test func renderRoundTripsThroughParse() throws {
        let entries = try distil(symbolGraph: graph([
            symbol(path: ["A"], kind: "swift.struct", declaration: "struct A"),
            symbol(path: ["A", "b"], kind: "swift.property", declaration: "var b: Int"),
        ]))
        let surface = parseSurface(render(entries))
        #expect(surface.count == 2)
        #expect(surface["A.b"]?.declarations == ["var b: Int"])
    }

    /// Overloads share a path. Keeping only one would hide a change to the other.
    @Test func overloadsAtOneKeyAreBothRecorded() {
        let surface = parseSurface("""
            f(a:)\tmethod\tfunc f(a: Int)
            f(a:)\tmethod\tfunc f(a: String)
            """)
        #expect(surface["f(a:)"]?.declarations.count == 2)
    }
}

@Suite struct SurfaceComparisonTests {

    func surface(_ pairs: [(String, String, String)]) -> Surface {
        parseSurface(pairs.map { "\($0.0)\t\($0.1)\t\($0.2)" }.joined(separator: "\n"))
    }

    let baseline: Surface

    init() {
        baseline = parseSurface("""
            CreateItemInput\tstruct\tstruct CreateItemInput
            CreateItemInput.edges\tproperty\tvar edges: [CreateItemEdge]?
            CreateItemEdge\tstruct\tstruct CreateItemEdge
            CreateItemEdge.edgeType\tproperty\tvar edgeType: String
            Reason\tenum\tenum Reason
            Reason.one\tenum.case\tcase one
            """)
    }

    @Test func anIdenticalSurfaceIsNoDifference() throws {
        #expect(try compare(baseline: baseline, current: baseline).isEmpty)
    }

    /// The permissive failure this whole check turns on. Two empty surfaces
    /// compare equal, so a broken extraction reads as "nothing changed" and
    /// waves every break through. Both sides refuse instead.
    ///
    /// Each side is pinned against a populated opposite, and on the specific
    /// error rather than on "it threw". Asserting only that something was
    /// thrown lets either guard stand in for the other: with the baseline
    /// guard deleted, `compare([:], [:])` still throws — from the *current*
    /// guard — and a test reading only the type calls that a pass.
    @Test func anEmptyBaselineRefusesRatherThanComparingEqual() {
        #expect(throws: PublicSurfaceError.emptyBaseline("the baseline")) {
            _ = try compare(baseline: [:], current: baseline)
        }
    }

    @Test func anEmptyCurrentSurfaceRefuses() {
        #expect(throws: PublicSurfaceError.emptyCurrent) {
            _ = try compare(baseline: baseline, current: [:])
        }
    }

    @Test func aRetypedPropertyIsChangedAndNotRemovedAndAdded() throws {
        var current = baseline
        current["CreateItemInput.edges"] = SurfaceEntry(
            kind: "property", declarations: ["var edges: [String : [String]]?"]
        )
        let diff = try compare(baseline: baseline, current: current)
        #expect(diff.changed == ["CreateItemInput.edges"])
        #expect(diff.removed.isEmpty)
        #expect(diff.added.isEmpty)
    }

    /// Removing a type removes its members too. Reporting both asks the
    /// changelog to name things that no longer have a type to belong to.
    @Test func removingATypeRollsUpItsMembers() throws {
        var current = baseline
        current["CreateItemEdge"] = nil
        current["CreateItemEdge.edgeType"] = nil
        let diff = try compare(baseline: baseline, current: current)
        #expect(diff.removed == ["CreateItemEdge"])
    }

    @Test func addingATypeRollsUpItsMembers() throws {
        var current = baseline
        current["MarfaAccountIdentity"] = SurfaceEntry(kind: "struct", declarations: ["struct MarfaAccountIdentity"])
        current["MarfaAccountIdentity.spaceId"] = SurfaceEntry(kind: "property", declarations: ["var spaceId: String"])
        let diff = try compare(baseline: baseline, current: current)
        #expect(diff.added == ["MarfaAccountIdentity"])
    }

    /// A closed enum gaining a case breaks an exhaustive switch. That is a
    /// property of the enum, and it is how the changelog describes it.
    @Test func anAddedEnumCaseIsReportedAsItsEnum() throws {
        var current = baseline
        current["Reason.two"] = SurfaceEntry(kind: "enum.case", declarations: ["case two"])
        let diff = try compare(baseline: baseline, current: current)
        #expect(diff.added.isEmpty)
        #expect(diff.changed == ["Reason"])
    }

    @Test func aRemovedEnumCaseIsReportedAsItsEnum() throws {
        var current = baseline
        current["Reason.one"] = nil
        let diff = try compare(baseline: baseline, current: current)
        #expect(diff.removed.isEmpty)
        #expect(diff.changed == ["Reason"])
    }
}

@Suite struct ChangelogAccountingTests {

    let changelog = """
        # Changelog

        ## [Unreleased]

        ### Changed

        - **`Transport.uploadMultipart(...)` requires an explicit `method:`**.

        ## [14.2.0] — 2026-08-27

        ### Removed

        - **`CreateItemEdge`, and `CreateItemInput.edges` changes shape with it.**
        """

    var unreleased: ChangelogSection { unreleasedSection(inChangelog: changelog) }

    @Test func aMemberNamedAsOwnerDotLeafIsAccountedFor() {
        #expect(unreleased.mentions("Transport.uploadMultipart(_:to:body:contentType:)"))
    }

    /// The permissive failure in the section parser: read past the next `##`
    /// and every name in the SDK's release history counts as accounted for,
    /// so the check quietly stops working once the project has a few versions.
    @Test func aNameFromAPreviousReleaseIsNotAccountedFor() {
        #expect(!unreleased.mentions("CreateItemEdge"))
        #expect(!unreleased.mentions("CreateItemInput.edges"))
    }

    /// The section ends at the next heading, deterministically. Without that,
    /// a second Unreleased-shaped heading further down would resume collecting
    /// and quietly widen what counts as accounted for.
    @Test func onlyTheFirstUnreleasedSectionIsRead() {
        let section = unreleasedSection(inChangelog: """
            ## [Unreleased]

            - `First` changed.

            ## [14.2.0]

            - a release.

            ## [Unreleased notes]

            - `Second` changed.
            """)
        #expect(section.mentions("First"))
        #expect(!section.mentions("Second"))
    }

    /// A changelog with no Unreleased section can account for nothing. Reading
    /// its absence as "nothing to declare" is the same hole from another side.
    @Test func aChangelogWithNoUnreleasedSectionAccountsForNothing() {
        let section = unreleasedSection(inChangelog: "# Changelog\n\n## [14.2.0]\n\n- `Foo` went away.\n")
        #expect(!section.mentions("Foo"))
    }

    /// Whole-word matching, so a new type called `Item` is not waved through by
    /// `CreateItemInput` appearing in an unrelated sentence.
    @Test func aSubstringOfAnotherNameIsNotAMention() {
        let section = unreleasedSection(inChangelog: "## [Unreleased]\n\n- `CreateItemInput` gained a field.\n")
        #expect(!section.mentions("Item"))
        #expect(section.mentions("CreateItemInput"))
    }

    /// An initialiser is described in terms of its type, so demanding the
    /// spelling `Foo.init` would refuse entries that are correct.
    @Test func anInitialiserIsAccountedForByItsTypeName() {
        let section = unreleasedSection(inChangelog: "## [Unreleased]\n\n- `CreateKeyInput`'s memberwise initialiser takes two more parameters.\n")
        #expect(section.mentions("CreateKeyInput.init(name:scopes:edgePermissions:)"))
    }

    /// The API is namespaced, so `AuthNamespace.me()` is written, read and
    /// called as `auth.me()`. A check demanding the type's spelling would
    /// refuse the way every namespace method here is already documented.
    @Test func aNamespaceMethodIsAccountedForByItsCallSpelling() {
        let section = unreleasedSection(inChangelog: "## [Unreleased]\n\n- **`auth.me()` wraps `GET /auth/me`.**\n")
        #expect(section.mentions("AuthNamespace.me()"))
    }

    /// The accommodation above must not become a wildcard: a different method
    /// on the same namespace is still unaccounted for.
    @Test func aNamespaceMethodTheEntryDoesNotNameIsStillReported() {
        let section = unreleasedSection(inChangelog: "## [Unreleased]\n\n- **`auth.me()` wraps `GET /auth/me`.**\n")
        #expect(!section.mentions("AuthNamespace.signOut()"))
    }

    @Test func anUnnamedDifferenceIsReported() {
        let diff = SurfaceDiff(removed: ["Vanished"], added: [], changed: [])
        let missing = unaccounted(in: diff, against: unreleased)
        #expect(missing.count == 1)
        #expect(missing[0].verdict == "removed")
        #expect(missing[0].key == "Vanished")
    }

    @Test func aNamedDifferenceIsNotReported() {
        let diff = SurfaceDiff(removed: [], added: [], changed: ["Transport.uploadMultipart(_:to:)"])
        #expect(unaccounted(in: diff, against: unreleased).isEmpty)
    }
}
