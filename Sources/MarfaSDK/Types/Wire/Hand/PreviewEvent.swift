import Foundation

/// Item-event type accepted by `POST /connections/preview-event`. Mirrors
/// the lifecycle events the reactive-run bridge emits for items.
public enum PreviewEventType: String, Codable, Sendable, Hashable, CaseIterable {
    case created
    case updated
    case deleted
    case restored
    case stateChanged = "state_changed"
    case metadataChanged = "metadata_changed"
}

/// Reason the bridge would or would not dispatch a given envelope to a
/// subscriber. Returned per subscriber in
/// ``PreviewEventEnvelope/dispatchReason``.
public enum PreviewEventDispatchReason: String, Codable, Sendable, Hashable, CaseIterable {
    /// The envelope would be dispatched.
    case ok

    /// Source connection equals the subscriber; the bridge skips
    /// self-feedback.
    case selfEvent = "self_event"

    /// Subscriber lives in a different tenant. Items never fan out
    /// across tenants.
    case crossTenant = "cross_tenant"

    /// Cycle hop count has reached the tenant's hop budget. The bridge
    /// stops here to prevent runaway reactive cycles.
    case hopBudgetExceeded = "hop_budget_exceeded"

    /// Subscriber's connection or webhook subscription is paused or
    /// revoked.
    case subscriptionInactive = "subscription_inactive"
}

/// Hop-count metadata supplied with a synthetic event. When omitted, the
/// preview behaves as if the event originated from outside any
/// connection cycle (`originating_connection_id: nil`, `hop_count: 0`).
public struct PreviewEventCycle: Codable, Sendable, Hashable {
    /// Connection id that originated the cycle, when known.
    public var originatingConnectionId: String?

    /// Current hop count. Bounded by the tenant's hop budget.
    public var hopCount: Int?

    public init(
        originatingConnectionId: String? = nil,
        hopCount: Int? = nil
    ) {
        self.originatingConnectionId = originatingConnectionId
        self.hopCount = hopCount
    }

    enum CodingKeys: String, CodingKey {
        case originatingConnectionId = "originating_connection_id"
        case hopCount = "hop_count"
    }
}

/// Body for `POST /connections/preview-event`.
public struct PreviewEventRequest: Codable, Sendable, Hashable {
    /// Item id the synthetic event would apply to. Required.
    public var itemId: String

    /// Lifecycle event being previewed. Required.
    public var eventType: PreviewEventType

    /// Limits the preview to one subscribing connection. When omitted,
    /// the response contains one entry per subscriber in the caller's
    /// tenant.
    public var connectionId: String?

    /// Cycle metadata override. Useful for reproducing
    /// `hop_budget_exceeded` scenarios.
    public var cycle: PreviewEventCycle?

    public init(
        itemId: String,
        eventType: PreviewEventType,
        connectionId: String? = nil,
        cycle: PreviewEventCycle? = nil
    ) {
        self.itemId = itemId
        self.eventType = eventType
        self.connectionId = connectionId
        self.cycle = cycle
    }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case eventType = "event_type"
        case connectionId = "connection_id"
        case cycle
    }
}

/// Hop-count cycle metadata embedded inside a synthesized queue body.
/// Distinct from ``PreviewEventCycle`` (the request override) — this is
/// the fully-resolved cycle the bridge would emit.
public struct PreviewEventQueueCycle: Codable, Sendable, Hashable {
    public let originatingConnectionId: String?
    public let hopCount: Int

    public init(originatingConnectionId: String?, hopCount: Int) {
        self.originatingConnectionId = originatingConnectionId
        self.hopCount = hopCount
    }

    enum CodingKeys: String, CodingKey {
        case originatingConnectionId = "originating_connection_id"
        case hopCount = "hop_count"
    }
}

/// The wire envelope the reactive-run bridge would POST to Cloudflare
/// Queues if the dispatch were real. Only populated on entries where
/// ``PreviewEventEnvelope/wouldDispatch`` is `true`.
public struct PreviewEventQueueBody: Codable, Sendable, Hashable {
    /// Envelope discriminator. Always `"item-event"` for the current
    /// surface; declared as a string so a future kind doesn't break
    /// decode.
    public let kind: String

    public let integrationName: String
    public let connectionId: String
    public let tenantId: String?
    public let eventType: String
    public let itemId: String
    public let cycle: PreviewEventQueueCycle

    /// Item payload at the time of the event. `nil` for `deleted`
    /// events where the body is no longer available.
    public let payload: JSONValue?

    public init(
        kind: String,
        integrationName: String,
        connectionId: String,
        tenantId: String?,
        eventType: String,
        itemId: String,
        cycle: PreviewEventQueueCycle,
        payload: JSONValue?
    ) {
        self.kind = kind
        self.integrationName = integrationName
        self.connectionId = connectionId
        self.tenantId = tenantId
        self.eventType = eventType
        self.itemId = itemId
        self.cycle = cycle
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case integrationName = "integration_name"
        case connectionId = "connection_id"
        case tenantId = "tenant_id"
        case eventType = "event_type"
        case itemId = "item_id"
        case cycle
        case payload
    }
}

/// One subscriber's would-dispatch result. `envelope` is populated only
/// when ``wouldDispatch`` is `true`; on a skip, ``dispatchReason``
/// explains why.
public struct PreviewEventEnvelope: Codable, Sendable, Hashable {
    public let connectionId: String
    public let integrationName: String
    public let wouldDispatch: Bool
    public let dispatchReason: PreviewEventDispatchReason
    public let envelope: PreviewEventQueueBody?

    public init(
        connectionId: String,
        integrationName: String,
        wouldDispatch: Bool,
        dispatchReason: PreviewEventDispatchReason,
        envelope: PreviewEventQueueBody?
    ) {
        self.connectionId = connectionId
        self.integrationName = integrationName
        self.wouldDispatch = wouldDispatch
        self.dispatchReason = dispatchReason
        self.envelope = envelope
    }

    enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case integrationName = "integration_name"
        case wouldDispatch = "would_dispatch"
        case dispatchReason = "dispatch_reason"
        case envelope
    }
}

/// Hop-budget snapshot returned alongside the envelopes.
public struct PreviewEventHopBudget: Codable, Sendable, Hashable {
    /// Configured hop ceiling for the caller's tenant.
    public let max: Int

    /// Hop count consumed by the cycle the preview was rendered against.
    public let used: Int

    public init(max: Int, used: Int) {
        self.max = max
        self.used = used
    }
}

/// Response from `POST /connections/preview-event`.
public struct PreviewEventResult: Codable, Sendable, Hashable {
    /// One entry per subscriber the operator asked about. May be empty
    /// when no subscribers exist for the event's type.
    public let envelopes: [PreviewEventEnvelope]

    /// The tenant's hop budget at the moment of the call.
    public let hopBudget: PreviewEventHopBudget

    public init(
        envelopes: [PreviewEventEnvelope],
        hopBudget: PreviewEventHopBudget
    ) {
        self.envelopes = envelopes
        self.hopBudget = hopBudget
    }

    enum CodingKeys: String, CodingKey {
        case envelopes
        case hopBudget = "hop_budget"
    }
}
