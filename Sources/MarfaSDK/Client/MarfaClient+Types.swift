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
        return .platform.merging(try await localStore.cachedTypeDefinitions())
    }

    /// Caches this space's type graph, so a write can be validated with no
    /// network.
    ///
    /// Called on the engine's own schedule for a synced client. It is public
    /// because a pure-local client that is handed a server later has no engine
    /// to do it, and because an app that knows it has just registered a type
    /// should not have to wait for a sync cycle to see it.
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
