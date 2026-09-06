import Foundation

/// Connection lifecycle namespace.
///
/// `system.connection` items are still managed via ``ItemsNamespace`` for
/// generic CRUD; this namespace adds the orchestrated lifecycle
/// operations (`install`, `uninstall`) plus convenience reads, lease-tokens
/// management, and inbound webhook administration.
///
/// Available in remote and synced modes. In **pure-local mode** every
/// method throws ``LocalModeUnsupportedError``.
public struct ConnectionsNamespace: Sendable {

    let transport: any Transport
    let items: ItemsNamespace
    let isLocalMode: Bool

    /// Lease tokens — short-lived bearer credentials issued for a
    /// connection. Surfaces as a sub-namespace because lease tokens have
    /// their own resource lifecycle (create/list/revoke) distinct from
    /// the connection itself.
    public let leaseTokens: LeaseTokensNamespace

    /// Inbound webhooks — incoming HTTP delivery subscriptions for a
    /// connection. Sub-namespace for the same reason as
    /// ``leaseTokens``.
    public let inboundWebhooks: InboundWebhooksNamespace

    init(transport: any Transport, items: ItemsNamespace, isLocalMode: Bool) {
        self.transport = transport
        self.items = items
        self.isLocalMode = isLocalMode
        self.leaseTokens = LeaseTokensNamespace(transport: transport, isLocalMode: isLocalMode)
        self.inboundWebhooks = InboundWebhooksNamespace(transport: transport, isLocalMode: isLocalMode)
    }

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Lists connection items. Wraps `items.list({type: "system.connection"})`
    /// and projects the result to the typed ``Connection`` domain model.
    ///
    /// Filter by ``ConnectionKind`` (`app | integration`) and/or
    /// ``ItemState`` (`active | revoked`). Local-store backed in synced
    /// mode.
    public func list(
        kind: ConnectionKind? = nil,
        state: ItemState? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> PaginatedResult<Connection> {
        var filters = ListFilters(
            type: Connection.typeIdentifier,
            state: state,
            limit: limit,
            cursor: cursor
        )
        if let kind {
            // The server supports filter on `properties.kind` via the
            // generic filter expression syntax.
            filters.filter = "kind=\"\(kind.rawValue)\""
        }
        let raw = try await items.list(filters: filters)
        return PaginatedResult(
            data: raw.data.compactMap { Connection(from: $0) },
            cursor: raw.cursor,
            hasMore: raw.hasMore
        )
    }

    /// Reads a single connection by id. Wraps `items.get(id)`.
    public func get(_ id: String) async throws -> Connection {
        let item = try await items.get(id: id)
        guard let connection = Connection(from: item) else {
            throw ValidationError(
                message: "item \(id) is not a system.connection (got \(item.type))",
                details: nil
            )
        }
        return connection
    }

    /// Installs an integration connection non-interactively via
    /// `POST /connections/install`.
    ///
    /// Skips the HTML consent screen — operators and tooling use this
    /// path to install connections programmatically. Admin-only; space
    /// admins install into their own space scope.
    ///
    /// `integrationId` references a `system.integration` item registered
    /// via ``IntegrationsNamespace/register(manifest:)``.
    ///
    /// `credentialRef` names an existing `system.credential` to bind the
    /// connection to instead of provisioning a fresh one, which is how two
    /// integrations against the same upstream — `google/calendar` and
    /// `google/tasks`, say — share a single OAuth client configuration.
    /// Create one through ``CredentialsNamespace``.
    ///
    /// `configuration` seeds the connection's `properties.configuration`
    /// bag, so per-integration settings land in the same round trip rather
    /// than in a follow-on update. The server validates the keys against the
    /// manifest's declared contract and refuses the install with a
    /// ``ValidationError`` naming any key the integration does not declare,
    /// so this is not a free-form bag despite its type.
    @discardableResult
    public func install(
        integrationId: String,
        credentialRef: String? = nil,
        configuration: [String: JSONValue]? = nil
    ) async throws -> ConnectionInstallResult {
        try ensureRemote("connections.install")
        let input = ConnectionInstallInput(
            configuration: configuration,
            credentialRef: credentialRef,
            integrationId: integrationId
        )
        return try await transport.request(
            method: .post, path: "/connections/install", body: input, query: nil
        )
    }

    /// Orchestrated uninstall via `POST /connections/{id}/uninstall`.
    ///
    /// Server-side pipeline:
    /// 1. Revokes runtime credentials.
    /// 2. Deletes the proxy's cached upstream OAuth tokens.
    /// 3. Revokes active leased tokens.
    /// 4. Disables inbound webhook subscriptions.
    /// 5. Removes the upstream credential the connection was installed
    ///    with, unless another live connection still shares it.
    /// 6. Transitions the connection state to `revoked`.
    /// 7. Emits a `system.activity` row.
    ///
    /// Idempotent at the artifact level, since revoking an already-revoked
    /// token is a no-op, but rejects with `400 ValidationError` when the
    /// connection itself is already in state `revoked`.
    ///
    /// ### Reading `upstreamCredential`
    ///
    /// Step 5 has four outcomes, and the field reports which one happened.
    /// It is typed as a free-form map because the spec declares it as an
    /// unnamed union, so there is no generated type to read it through.
    /// Discriminate on `status`:
    ///
    /// - `none`: the connection had no upstream credential. No other keys.
    /// - `already_gone`: it was gone before this call. Carries
    ///   `credential_id`.
    /// - `purged`: this call deleted it. Carries `credential_id`.
    /// - `retained`: left in place because other live connections use it.
    ///   Carries `credential_id`, `reason`
    ///   (`in_use_by_other_connections`) and `connection_ids`, the
    ///   connections that kept it alive.
    ///
    /// A caller wanting the upstream account fully disconnected wants
    /// `purged` or `already_gone`. `retained` means the account is still
    /// reachable through the connections it names.
    ///
    /// Synonym: this is sometimes called "revoke" colloquially. The wire
    /// spelling is "uninstall"; this method matches.
    @discardableResult
    public func uninstall(_ id: String) async throws -> ConnectionUninstallResult {
        try ensureRemote("connections.uninstall")
        return try await transport.request(
            method: .post,
            path: "/connections/\(id.escapedPathSegment)/uninstall",
            body: nil,
            query: nil
        )
    }

    /// Renders the wire envelopes the reactive-run bridge would POST to
    /// Cloudflare Queues for a synthetic item event, without dispatching
    /// anything. Operator debugging surface for reproducing reactive
    /// scenarios and inspecting `dispatch_reason` skips
    /// (`self_event`, `cross_space`, `hop_budget_exceeded`,
    /// `subscription_inactive`).
    ///
    /// Defaults to every subscriber in the caller's space; pass
    /// ``PreviewEventRequest/connectionId`` to filter to one.
    /// Space-admin only.
    public func previewEvent(_ input: PreviewEventRequest) async throws -> PreviewEventResult {
        try ensureRemote("connections.previewEvent")
        return try await transport.request(
            method: .post,
            path: "/connections/preview-event",
            body: input,
            query: nil
        )
    }
}

/// Lease token sub-namespace under ``ConnectionsNamespace``. Manages
/// the short-lived bearer credentials a connection mints for a specific
/// capability.
public struct LeaseTokensNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Creates a lease token via `POST /connections/{id}/lease-tokens`.
    ///
    /// Returns a ``CreatedLeaseToken`` containing the actual token string
    /// in `lease_token` — this is the **only** time the token value is
    /// returned to the caller; subsequent `list` calls return the
    /// metadata without the token value.
    public func create(
        connectionId: String,
        capabilityId: String,
        scopes: [String]? = nil,
        ttlSeconds: Int? = nil
    ) async throws -> CreatedLeaseToken {
        try ensureRemote("connections.leaseTokens.create")
        let input = LeaseTokenInput(
            capabilityId: capabilityId,
            scopes: scopes,
            ttlSeconds: ttlSeconds
        )
        return try await transport.request(
            method: .post,
            path: "/connections/\(connectionId.escapedPathSegment)/lease-tokens",
            body: input,
            query: nil
        )
    }

    /// Lists active lease tokens for a connection. Token values are not
    /// returned — only id, scopes, expiry, and revocation status.
    public func list(connectionId: String) async throws -> [LeaseToken] {
        try ensureRemote("connections.leaseTokens.list")
        let response: LeaseTokensListResponse = try await transport.request(
            method: .get,
            path: "/connections/\(connectionId.escapedPathSegment)/lease-tokens",
            body: nil,
            query: nil
        )
        return response.leases
    }

    /// Revokes a lease token via
    /// `POST /connections/{id}/lease-tokens/{leaseId}/revoke`. Idempotent.
    public func revoke(connectionId: String, leaseId: String) async throws {
        try ensureRemote("connections.leaseTokens.revoke")
        let _: EmptyResponse = try await transport.request(
            method: .post,
            path: "/connections/\(connectionId.escapedPathSegment)/lease-tokens/\(leaseId.escapedPathSegment)/revoke",
            body: nil,
            query: nil
        )
    }
}

/// Inbound webhook sub-namespace under ``ConnectionsNamespace``.
public struct InboundWebhooksNamespace: Sendable {

    let transport: any Transport
    let isLocalMode: Bool

    private func ensureRemote(_ operation: String) throws {
        if isLocalMode {
            throw LocalModeUnsupportedError(operation: operation)
        }
    }

    /// Lists inbound webhook subscriptions for a connection.
    public func list(connectionId: String) async throws -> [InboundWebhookSubscription] {
        try ensureRemote("connections.inboundWebhooks.list")
        let response: InboundWebhooksListResponse = try await transport.request(
            method: .get,
            path: "/connections/\(connectionId.escapedPathSegment)/inbound-webhooks",
            body: nil,
            query: nil
        )
        return response.inboundWebhooks
    }

    /// Lists deliveries for a specific inbound webhook.
    public func listDeliveries(
        connectionId: String,
        webhookId: String
    ) async throws -> [InboundWebhookDelivery] {
        try ensureRemote("connections.inboundWebhooks.listDeliveries")
        let response: InboundWebhookDeliveriesResponse = try await transport.request(
            method: .get,
            path: "/connections/\(connectionId.escapedPathSegment)/inbound-webhooks/\(webhookId.escapedPathSegment)/deliveries",
            body: nil,
            query: nil
        )
        return response.deliveries
    }

    /// Manually retries a failed delivery via
    /// `POST /connections/{id}/inbound-webhooks/{webhookId}/deliveries/{eventId}/retry`.
    public func retryDelivery(
        connectionId: String,
        webhookId: String,
        eventId: String
    ) async throws {
        try ensureRemote("connections.inboundWebhooks.retryDelivery")
        let _: EmptyResponse = try await transport.request(
            method: .post,
            path: "/connections/\(connectionId.escapedPathSegment)/inbound-webhooks/\(webhookId.escapedPathSegment)/deliveries/\(eventId.escapedPathSegment)/retry",
            body: nil,
            query: nil
        )
    }
}
