import Foundation

/// Integrations API namespace. Manages registered Integration manifests
/// — the persisted form of an Integration declaration that connections
/// install against.
///
/// Each `(publisher.name, version)` pair lands as a sibling
/// `system.integration` item; subsequent releases of the same Integration
/// don't update in place. A connection installed against v1.0 keeps
/// pointing at the manifest item it was installed with even after v1.1
/// lands.
///
/// In **pure-local mode** every method throws ``LocalModeUnsupportedError``.
public struct IntegrationsNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Lists registered Integration manifests via `GET /integrations`.
    ///
    /// Optionally filtered by `manifestName` (publisher-namespaced
    /// manifest name, e.g. `"acme.calendar-sync"`) to fetch all versions
    /// of one Integration. `limit` clamps the page size (server max 200).
    public func list(
        manifestName: String? = nil,
        limit: Int? = nil
    ) async throws -> [Integration] {
        try ensureRemote("integrations.list")
        var query: [(String, String)] = []
        if let manifestName { query.append(("manifest_name", manifestName)) }
        if let limit { query.append(("limit", String(limit))) }
        let response: IntegrationsListResponse = try await transport.request(
            method: .get,
            path: "/integrations",
            body: nil,
            query: query.isEmpty ? nil : query
        )
        return response.data
    }

    /// Reads a registered Integration by id via `GET /integrations/{id}`.
    public func get(_ id: String) async throws -> Integration {
        try ensureRemote("integrations.get")
        return try await transport.request(
            method: .get,
            path: "/integrations/\(id.escapedPathSegment)",
            body: nil,
            query: nil
        )
    }

    /// Registers an Integration manifest via `POST /integrations`.
    ///
    /// The server validates the manifest shape, persists it as a
    /// `system.integration` item, and returns the resulting record.
    /// Platform-credential gated.
    @discardableResult
    public func register(manifest: [String: JSONValue]) async throws -> Integration {
        try ensureRemote("integrations.register")
        let input = RegisterIntegrationInput(manifest: manifest)
        return try await transport.request(
            method: .post,
            path: "/integrations",
            body: input,
            query: nil
        )
    }
}
