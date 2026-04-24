import Foundation

/// Webhooks API namespace. Manages webhook registration and delivery history.
///
/// A client created via ``MymeClient/local(path:)`` has no live server;
/// every method here throws ``LocalModeUnsupportedError``.
public struct WebhooksNamespace: Sendable {

    let transport: any Transport

    /// `true` when this namespace is attached to a pure-local client. When
    /// set, every method throws before touching the transport.
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Creates a new webhook.
    public func create(_ input: CreateWebhookInput) async throws -> Webhook {
        try ensureRemote("webhooks.create")
        return try await transport.request(
            method: .post, path: "/webhooks", body: input, query: nil
        )
    }

    /// Lists all registered webhooks.
    public func list() async throws -> [Webhook] {
        try ensureRemote("webhooks.list")
        let response: WebhooksListResponse = try await transport.request(
            method: .get, path: "/webhooks", body: nil, query: nil
        )
        return response.webhooks
    }

    /// Gets a single webhook by ID.
    public func get(id: String) async throws -> Webhook {
        try ensureRemote("webhooks.get")
        return try await transport.request(
            method: .get, path: "/webhooks/\(id)", body: nil, query: nil
        )
    }

    /// Updates a webhook.
    public func update(id: String, input: UpdateWebhookInput) async throws -> Webhook {
        try ensureRemote("webhooks.update")
        return try await transport.request(
            method: .patch, path: "/webhooks/\(id)", body: input, query: nil
        )
    }

    /// Deletes a webhook.
    public func delete(id: String) async throws {
        try ensureRemote("webhooks.delete")
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/webhooks/\(id)", body: nil, query: nil
        )
    }

    /// Lists delivery attempts for a webhook.
    public func deliveries(id: String, limit: Int? = nil) async throws -> [WebhookDelivery] {
        try ensureRemote("webhooks.deliveries")
        var query: [(String, String)] = []
        if let limit { query.append(("limit", String(limit))) }
        let response: DeliveriesResponse = try await transport.request(
            method: .get, path: "/webhooks/\(id)/deliveries", body: nil,
            query: query.isEmpty ? nil : query
        )
        return response.deliveries
    }
}
