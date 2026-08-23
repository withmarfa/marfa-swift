import Foundation

/// Holds the app's live conflict resolver so a replayed mutation can reach it.
///
/// A `.callback` strategy names a closure, and a closure cannot be written to
/// a mutation queue. In synced mode the write that raced is almost never the
/// one the app made online: it is the replay, minutes or a launch later,
/// against a server the app could not reach at the time. That is precisely
/// when app-specific merge logic matters most, and it is exactly where the
/// closure has been lost.
///
/// The resolver is therefore registered on the client rather than passed per
/// call, and replay looks it up here. Registration is by identity, not by
/// serialization, so it survives a process restart in the only way a closure
/// can: the app installs it again on launch, before the engine starts
/// draining.
///
/// Nothing here silently substitutes one strategy for another. A `.callback`
/// update in synced mode is refused at the call site when no resolver is
/// registered, and a replay that somehow finds none keeps the mutation queued
/// rather than merging it under different rules.
public actor ConflictResolverRegistry {
    private var resolver: ConflictResolver?

    public init(resolver: ConflictResolver? = nil) {
        self.resolver = resolver
    }

    /// Install the resolver replayed `.callback` updates will run through.
    /// Call this before starting the sync engine; a later registration is
    /// honored, but mutations that drained in the meantime will have waited.
    public func register(_ resolver: @escaping ConflictResolver) {
        self.resolver = resolver
    }

    /// Remove the registered resolver. A queued `.callback` mutation then
    /// waits rather than resolving under a different strategy.
    public func clear() {
        resolver = nil
    }

    /// The registered resolver, or `nil` when the app has installed none.
    public func current() -> ConflictResolver? {
        resolver
    }

    public var isRegistered: Bool {
        resolver != nil
    }
}

/// Raised when a `.callback` update cannot reach a resolver.
///
/// Three moments produce it, and all three are the alternative to a strategy
/// quietly becoming a different one:
///
/// - At the call site on a synced client, when the update asks for
///   `.callback` and no resolver is registered. The caller learns at the point
///   of the mistake rather than at a replay they are not watching.
/// - At replay, when the mutation was enqueued with a resolver registered and
///   none is registered now. The mutation stays queued; registering a
///   resolver lets the next drain carry it.
/// - At the call site on a local-only client, which never syncs and so can
///   reach no resolver at all. Registering one does not help there, and the
///   message says so rather than sending the caller round a loop.
public final class ConflictResolverMissingError: MarfaError {
    public init(message: String) {
        super.init(
            code: "conflict_resolver_not_registered",
            message: message,
            status: 0
        )
    }

    /// Never permanent, which is a statement about the replay path and only
    /// that path. A queued mutation is replayable the moment the app registers
    /// a resolver, and dropping it would lose the user's edit for a reason
    /// that has nothing to do with the edit.
    ///
    /// The local-only refusal is not replayable in that sense, because there
    /// is no queue to replay from. It also never reaches anything that reads
    /// this: `SyncEngine` is the only consumer, and a local-only client has no
    /// sync engine. Left `false` rather than made conditional, so the value
    /// keeps meaning one thing for the path that reads it.
    public override var isPermanent: Bool { false }
}
