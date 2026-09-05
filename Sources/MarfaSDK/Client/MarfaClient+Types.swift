import Foundation

extension MarfaClient {
    /// The type graph this client validates against: the platform types the
    /// SDK ships with, plus whatever this space's own types were last cached.
    ///
    /// **The space's copy wins a collision**, because a space may re-register
    /// an id the platform also declares and its rows were written against the
    /// space's shape, not the shipped one.
    ///
    /// A client with no store answers with the platform set alone. That is not
    /// a degraded answer — a remote client validates at the server, which is
    /// the authority, and a local check there would only duplicate it.
    public func typeRegistry() async throws -> MarfaTypeRegistry {
        guard let localStore else { return .platform }
        // `.resolved()` is not optional decoration. `GET /types` answers with
        // schemas as declared, so a cached type carries only its own fields —
        // and a cached copy of a *platform* type would otherwise overlay the
        // generated, already-flattened one and quietly stop enforcing
        // everything it inherits.
        return .platform.merging(try await localStore.cachedTypeDefinitions()).resolved()
    }

    /// Caches this space's type graph, so a write can be validated with no
    /// network.
    ///
    /// **Nothing calls this on a schedule yet**, so a client's cache is
    /// whatever its app last asked for. That is the honest state rather than
    /// the intended one: the graph changes when a type is registered, which
    /// an app knows about and a timer does not, and wiring it into the sync
    /// cycle is tracked separately. Until then an app that registers a type,
    /// or that wants offline validation to know about the space's types at
    /// all, calls this itself.
    ///
    /// **Throws rather than failing quietly.** A refresh that cannot reach the
    /// server leaves the previous cache in place, which is the right outcome —
    /// a stale graph validates better than none — but a caller asking for a
    /// refresh is entitled to know it did not happen.
    @discardableResult
    public func refreshCachedTypes() async throws -> Int {
        guard let localStore else {
            throw LocalModeUnsupportedError(operation: "refreshCachedTypes")
        }
        let schemas = try await types.list()
        try await localStore.replaceCachedTypes(with: schemas)
        return schemas.count
    }
}
