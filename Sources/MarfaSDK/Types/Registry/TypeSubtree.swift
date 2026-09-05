import Foundation

/// What a read filter's `type=` selects, decomposed the way a fetch
/// predicate needs it.
///
/// **A bare identifier selects its subtree on a read**, which is not how the
/// same string reads elsewhere: `?type=core.entity` has always returned
/// `core.entity.person` too, while `core.entity` as a *permission* grant is
/// exact and must not reach descendants. Same strings, opposite defaults, so
/// this deliberately answers only the read question.
///
/// The subtree is a union of two things, and both halves are load-bearing:
///
/// - **The namespace.** Everything under the dotted name. This needs no
///   registry, so it holds on a device that has never reached a server.
/// - **The declared lineage.** Everything that names its way there. This
///   needs the registry, and is empty without one — which is the same
///   answer a read gave before a registry existed, rather than a wrong one.
///
/// Resolving names alone was the divergence: a child registered under a
/// different namespace was missing from a query against its own parent, with
/// no error to say so. Resolving declarations alone would break the other
/// half, since nothing declares a parent of `google` yet `google.*` plainly
/// means the Google types.
///
/// **There is no "matches everything" filter, and adding one was a defect.**
/// `GET /items` refuses `?type=*` outright — everything is a listing with no
/// type at all, and a filter matching every type would slip past the per-type
/// enforcement levers keyed off the parameter. So a pattern this device
/// cannot make sense of resolves to a subtree nothing is in, never to an
/// unnarrowed read. Every unresolvable spelling — `*`, `*.*`, `.*`, a
/// trailing dot — comes back empty here where the server answers `400`.
/// Different in kind, identical in what a caller sees, and wrong only in the
/// direction that shows too little rather than too much.
struct TypeSubtree: Sendable, Equatable {
    /// The identifier to compare with equality.
    let root: String
    /// The prefix descent matches on.
    ///
    /// Normally `root` plus a dot. Deliberately **unmatchable** when the root
    /// is the bare `system` namespace: the server decides that exclusion from
    /// the *raw* filter string, so `system` and `system.*` are different
    /// questions to it, while stripping the wildcard makes them one root here.
    /// Without this, `?type=system` returned every device, connection and
    /// activity row into a listing and into an app's search field.
    let namespace: String
    /// Declared descendants the namespace walk cannot reach. Empty when no
    /// registry was supplied.
    let declaredExtras: Set<String>

    /// A prefix no type identifier can start with, so the descent term is
    /// present and matches nothing. A dotted identifier cannot contain a NUL.
    static let unmatchablePrefix = "\u{0}"

    /// Resolves a filter string, with `registry` supplying the declared half.
    ///
    /// `core.entity` and `core.entity.*` are synonyms, as they are on the
    /// server. The caller decides what an *absent* filter means; an empty
    /// string never reaches here.
    init(filter: String, registry: MarfaTypeRegistry? = nil) {
        let root = filter.hasSuffix(".*") ? String(filter.dropLast(2)) : filter
        self.init(
            root: root,
            declaredExtras: registry?.declaredDescendantsOutsideNamespace(of: root) ?? [],
            namesASystemType: filter.hasPrefix(Self.systemPrefix)
        )
    }

    /// A subtree whose declared half a caller has already resolved.
    ///
    /// `namesASystemType` is asked about the **raw** filter rather than
    /// derived from `root`, because that is the distinction `root` has
    /// already thrown away.
    init(root: String, declaredExtras: Set<String>, namesASystemType: Bool) {
        self.root = root
        self.namespace = (!namesASystemType && (root + ".").hasPrefix(Self.systemPrefix))
            ? Self.unmatchablePrefix
            : root + "."
        // A declared child of an ordinary type that happens to be named under
        // `system.` is the other way a system row could reach a listing that
        // excludes them, and the namespace above cannot see it.
        self.declaredExtras = namesASystemType
            ? declaredExtras
            : declaredExtras.filter { !$0.hasPrefix(Self.systemPrefix) }
    }

    /// Every identifier the predicate compares by equality: the root, plus
    /// the declared descendants the prefix cannot reach.
    var matchedIds: Set<String> { declaredExtras.union([root]) }

    static let systemPrefix = "system."
}
