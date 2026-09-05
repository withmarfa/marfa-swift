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
struct TypeSubtree: Sendable, Equatable {
    /// The filter selects every type; emit no type clause at all.
    let isGlobal: Bool
    /// The identifier to compare with equality, and the namespace to descend.
    let root: String
    /// Declared descendants the namespace walk cannot reach. Empty when no
    /// registry was supplied.
    let declaredExtras: Set<String>

    /// Every type identifier that means "all of them".
    static let globalWildcard = "*"

    /// Resolves a filter string, with `registry` supplying the declared half.
    ///
    /// `core.entity` and `core.entity.*` are synonyms here, as they are on the
    /// server: a caller who spells the wildcard means what a caller who omits
    /// it already got.
    init(filter: String, registry: MarfaTypeRegistry? = nil) {
        if filter == Self.globalWildcard {
            self.isGlobal = true
            self.root = filter
            self.declaredExtras = []
            return
        }
        let root = filter.hasSuffix(".*") ? String(filter.dropLast(2)) : filter
        self.isGlobal = root.isEmpty
        self.root = root
        self.declaredExtras = root.isEmpty
            ? []
            : registry?.declaredDescendantsOutsideNamespace(of: root) ?? []
    }

    /// A subtree whose declared half a caller has already resolved.
    init(root: String, declaredExtras: Set<String>) {
        self.isGlobal = root.isEmpty || root == Self.globalWildcard
        self.root = root
        self.declaredExtras = declaredExtras
    }
}
