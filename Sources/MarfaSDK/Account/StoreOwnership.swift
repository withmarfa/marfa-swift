import Foundation

/// Whether a local store belongs to the account a credential reaches.
///
/// Four cases rather than a boolean, and the fourth is the one that matters.
/// **"Cannot tell" must not collapse into "same account"**, because the two
/// consumers of this answer have to fail in opposite directions:
///
/// - Deciding whether to **discard** a store, failing to resolve must mean *do
///   nothing*. Wiping on a network blip destroys data the person still wants,
///   and a stale store is reconciled by the next sync anyway.
/// - Deciding whether to **upload** a store, it must mean *stop*. Writing one
///   account's library into another's space cannot be undone, and another
///   person can read it.
///
/// A single boolean cannot carry that, and a consumer modelling it as "did the
/// account change" gets one of the two backwards. One did.
public enum StoreOwnership: Sendable, Equatable, Hashable {

    /// The store has never been claimed by any account.
    ///
    /// A store built in local mode, or one whose claim predates this being
    /// recorded. Not the same as empty: it may hold a whole library that has
    /// simply never been anywhere.
    case unclaimed

    /// The store belongs to the account the credential reaches. Resume.
    case sameAccount

    /// The store belongs to a different account.
    ///
    /// Nothing in it should be uploaded, and what happens to it locally —
    /// discarded, kept, moved aside — is the consumer's policy rather than the
    /// SDK's.
    case differentAccount

    /// The account behind the credential could not be determined.
    ///
    /// Typically offline, or a credential the server refused. Deliberately not
    /// merged into ``sameAccount``: see the note above about the two callers
    /// needing to fail in opposite directions.
    case unresolved
}
