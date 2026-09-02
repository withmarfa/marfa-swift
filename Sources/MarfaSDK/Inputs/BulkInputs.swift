import Foundation

// MARK: - /items/bulk — list-in

/// One item to create-or-upsert in a bulk call. Shape matches
/// `CreateItemInput` plus inline edges scoped to bulk writes.
///
/// `edges` uses the server shape, `{ <edge_type>: [targetId] }`: outbound
/// only, no per-edge properties, which is what the `/items/bulk` route
/// accepts verbatim. `CreateItemInput` carries the same shape for the same
/// reason.
public struct BulkItemInput: Codable, Sendable {
    /// The caller's own id for this item. A synced client writes the local
    /// row under it and sends it on replay, so it names the row on both
    /// sides. Omitted, the id is minted — locally by the store on a synced
    /// client, by the server otherwise.
    public var id: String?
    public var type: String
    public var properties: [String: JSONValue]?
    public var state: ItemState?
    public var tier: Tier?
    public var timestamp: String?
    /// Client-supplied `source` is ignored by the server — `source` is
    /// always stamped from the credential. Kept here because the server
    /// accepts the field (just throws it away) and the plan calls out
    /// non-forgeability as an explicit contract.
    public var source: String?
    public var sourceId: String?
    public var device: String?
    public var tags: [String]?
    /// Outbound edges to create atomically after the item write.
    /// Replace-all semantics: any edge_type listed wipes existing
    /// outbound edges of that type, then creates edges to each target.
    /// Empty array deletes all edges of that type. Absent = untouched.
    public var edges: [String: [String]]?

    public init(
        id: String? = nil,
        type: String,
        properties: [String: JSONValue]? = nil,
        state: ItemState? = nil,
        tier: Tier? = nil,
        timestamp: String? = nil,
        source: String? = nil,
        sourceId: String? = nil,
        device: String? = nil,
        tags: [String]? = nil,
        edges: [String: [String]]? = nil
    ) {
        self.id = id
        self.type = type
        self.properties = properties
        self.state = state
        self.tier = tier
        self.timestamp = timestamp
        self.source = source
        self.sourceId = sourceId
        self.device = device
        self.tags = tags
        self.edges = edges
    }

    enum CodingKeys: String, CodingKey {
        case id, type, properties, state, tier, timestamp, source, device, tags, edges
        case sourceId = "source_id"
    }
}

/// Upsert mode. `upsert` (default) updates matching `(source, source_id)`
/// rows in place; `createOnly` skips matching rows.
public enum BulkMode: String, Codable, Sendable {
    case upsert
    case createOnly = "create_only"
}

/// Input envelope for `POST /items/bulk`.
public struct BulkInput: Codable, Sendable {
    public var items: [BulkItemInput]
    public var mode: BulkMode?
    /// Defaults to `true` on the server — set `false` for best-effort ingest.
    public var atomic: Bool?
    /// Per-item `created`/`updated` events default to OFF to avoid
    /// webhook fanout on bulk calls.
    public var emitEvents: Bool?

    public init(
        items: [BulkItemInput],
        mode: BulkMode? = nil,
        atomic: Bool? = nil,
        emitEvents: Bool? = nil
    ) {
        self.items = items
        self.mode = mode
        self.atomic = atomic
        self.emitEvents = emitEvents
    }

    enum CodingKeys: String, CodingKey {
        case items, mode, atomic
        case emitEvents = "emit_events"
    }
}

public enum BulkOutcome: String, Codable, Sendable {
    case created
    case updated
    case skipped
    case errored
}

public struct BulkResultError: Codable, Sendable {
    public let code: String
    public let message: String
}

public struct BulkResultEntry: Codable, Sendable {
    public let index: Int
    public let outcome: BulkOutcome
    public let id: String?
    public let reason: String?
    public let error: BulkResultError?
}

public struct BulkResultCounts: Codable, Sendable {
    public let created: Int
    public let updated: Int
    public let skipped: Int
    public let errored: Int
}

public struct BulkResult: Codable, Sendable {
    public let counts: BulkResultCounts
    public let results: [BulkResultEntry]
    public let blobsImported: Int?

    enum CodingKeys: String, CodingKey {
        case counts, results
        case blobsImported = "blobs_imported"
    }
}

// MARK: - /items/bulk-actions — filter-in

/// Filter shape for `bulk_action` calls. Mirrors the `GET /items` query
/// grammar — every field is AND-composed.
public struct BulkActionFilter: Codable, Sendable {
    public var type: String?
    public var state: ItemState?
    public var source: String?
    public var tier: TierFilter?
    public var tags: [String]?
    public var since: String?
    public var until: String?
    /// Full filter-SQL DSL expression, identical grammar to
    /// `GET /items?filter=`. `edge[type]=id` and `backref[type]=id`
    /// URL shorthand translates to `edge[type] eq "id"` here.
    public var filter: String?

    public init(
        type: String? = nil,
        state: ItemState? = nil,
        source: String? = nil,
        tier: TierFilter? = nil,
        tags: [String]? = nil,
        since: String? = nil,
        until: String? = nil,
        filter: String? = nil
    ) {
        self.type = type
        self.source = source
        self.state = state
        self.tier = tier
        self.tags = tags
        self.since = since
        self.until = until
        self.filter = filter
    }
}

/// Shared knobs that every bulk action accepts.
public struct BulkActionOptions: Sendable {
    public var dryRun: Bool?
    /// Required literal `"PURGE"` on purge actions; the typed initializer
    /// ``BulkActionInput/purge(filter:options:)`` refuses to encode without it.
    public var confirm: String?
    public var maxItems: Int?
    public var emitEvents: Bool?

    public init(
        dryRun: Bool? = nil,
        confirm: String? = nil,
        maxItems: Int? = nil,
        emitEvents: Bool? = nil
    ) {
        self.dryRun = dryRun
        self.confirm = confirm
        self.maxItems = maxItems
        self.emitEvents = emitEvents
    }
}

/// Discriminated union over the six bulk actions. Encoded as a flat JSON
/// object keyed by `action` plus per-case parameters, matching the
/// server's discriminator.
public enum BulkActionInput: Codable, Sendable {
    case transition(filter: BulkActionFilter, state: ItemState, options: BulkActionOptions = .init())
    case purge(filter: BulkActionFilter, options: BulkActionOptions)
    case updateTags(filter: BulkActionFilter, add: [String]? = nil, remove: [String]? = nil, options: BulkActionOptions = .init())
    case updateTier(filter: BulkActionFilter, tier: Tier, options: BulkActionOptions = .init())
    case updateProperties(filter: BulkActionFilter, patch: [String: JSONValue], options: BulkActionOptions = .init())
    case updateTimestamp(filter: BulkActionFilter, timestamp: String, options: BulkActionOptions = .init())

    private enum CodingKeys: String, CodingKey {
        case action
        case filter
        case state
        case confirm
        case add
        case remove
        case tier
        case patch
        case timestamp
        case dryRun = "dry_run"
        case maxItems = "max_items"
        case emitEvents = "emit_events"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .transition(let filter, let state, let options):
            try c.encode("transition", forKey: .action)
            try c.encode(filter, forKey: .filter)
            try c.encode(state, forKey: .state)
            try encodeOptions(options, into: &c)

        case .purge(let filter, let options):
            guard options.confirm == "PURGE" else {
                throw EncodingError.invalidValue(
                    options,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: #"bulk_action(.purge) requires options.confirm == "PURGE""#
                    )
                )
            }
            try c.encode("purge", forKey: .action)
            try c.encode(filter, forKey: .filter)
            try c.encode("PURGE", forKey: .confirm)
            try encodeOptions(options, into: &c, includeConfirm: false)

        case .updateTags(let filter, let add, let remove, let options):
            try c.encode("update_tags", forKey: .action)
            try c.encode(filter, forKey: .filter)
            try c.encodeIfPresent(add, forKey: .add)
            try c.encodeIfPresent(remove, forKey: .remove)
            try encodeOptions(options, into: &c)

        case .updateTier(let filter, let tier, let options):
            try c.encode("update_tier", forKey: .action)
            try c.encode(filter, forKey: .filter)
            try c.encode(tier, forKey: .tier)
            try encodeOptions(options, into: &c)

        case .updateProperties(let filter, let patch, let options):
            try c.encode("update_properties", forKey: .action)
            try c.encode(filter, forKey: .filter)
            try c.encode(patch, forKey: .patch)
            try encodeOptions(options, into: &c)

        case .updateTimestamp(let filter, let timestamp, let options):
            try c.encode("update_timestamp", forKey: .action)
            try c.encode(filter, forKey: .filter)
            try c.encode(timestamp, forKey: .timestamp)
            try encodeOptions(options, into: &c)
        }
    }

    public init(from decoder: Decoder) throws {
        // Replay path: queued `bulkAction` mutations round-trip through
        // JSON, so we need to decode our own wire shape. The server never
        // sends this payload back — only the replay queue does.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let action = try c.decode(String.self, forKey: .action)
        let filter = try c.decode(BulkActionFilter.self, forKey: .filter)
        var options = BulkActionOptions()
        options.dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun)
        options.maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems)
        options.emitEvents = try c.decodeIfPresent(Bool.self, forKey: .emitEvents)

        switch action {
        case "transition":
            let state = try c.decode(ItemState.self, forKey: .state)
            self = .transition(filter: filter, state: state, options: options)
        case "purge":
            options.confirm = try c.decodeIfPresent(String.self, forKey: .confirm)
            self = .purge(filter: filter, options: options)
        case "update_tags":
            let add = try c.decodeIfPresent([String].self, forKey: .add)
            let remove = try c.decodeIfPresent([String].self, forKey: .remove)
            self = .updateTags(filter: filter, add: add, remove: remove, options: options)
        case "update_tier":
            let tier = try c.decode(Tier.self, forKey: .tier)
            self = .updateTier(filter: filter, tier: tier, options: options)
        case "update_properties":
            let patch = try c.decode([String: JSONValue].self, forKey: .patch)
            self = .updateProperties(filter: filter, patch: patch, options: options)
        case "update_timestamp":
            let timestamp = try c.decode(String.self, forKey: .timestamp)
            self = .updateTimestamp(filter: filter, timestamp: timestamp, options: options)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: c,
                debugDescription: "Unknown bulk_action discriminator: \(action)"
            )
        }
    }

    private func encodeOptions(
        _ options: BulkActionOptions,
        into container: inout KeyedEncodingContainer<CodingKeys>,
        includeConfirm: Bool = true
    ) throws {
        try container.encodeIfPresent(options.dryRun, forKey: .dryRun)
        try container.encodeIfPresent(options.maxItems, forKey: .maxItems)
        try container.encodeIfPresent(options.emitEvents, forKey: .emitEvents)
        if includeConfirm {
            try container.encodeIfPresent(options.confirm, forKey: .confirm)
        }
    }
}

public struct BulkActionErrorEntry: Codable, Sendable {
    public let id: String
    public let code: String
    public let message: String
}

public struct BulkActionResult: Codable, Sendable {
    public let action: String
    public let matched: Int
    public let succeeded: Int
    public let errored: Int
    public let dryRun: Bool
    public let ids: [String]?
    public let errors: [BulkActionErrorEntry]?
    /// Unique blob hashes referenced by purged items. Present on purge
    /// actions only. Callers that need a true orphan count should wait
    /// for blob GC — this is the best-effort snapshot from the one
    /// call.
    public let blobHashesReferenced: Int?

    enum CodingKeys: String, CodingKey {
        case action, matched, succeeded, errored, ids, errors
        case dryRun = "dry_run"
        case blobHashesReferenced = "blob_hashes_referenced"
    }

    public init(
        action: String,
        matched: Int,
        succeeded: Int,
        errored: Int,
        dryRun: Bool,
        ids: [String]?,
        errors: [BulkActionErrorEntry]?,
        blobHashesReferenced: Int?
    ) {
        self.action = action
        self.matched = matched
        self.succeeded = succeeded
        self.errored = errored
        self.dryRun = dryRun
        self.ids = ids
        self.errors = errors
        self.blobHashesReferenced = blobHashesReferenced
    }
}

/// Terminal vs non-terminal lifecycle states for an async `bulk_action` job.
/// The worker only transitions `queued` → `in_progress` → terminal;
/// terminal values freeze the row.
public enum BulkActionJobStatus: String, Codable, Sendable {
    case queued
    case inProgress = "in_progress"
    case completed
    case failed
    case cancelled
}

/// Async-job envelope returned by `POST /items/bulk-actions` (non-dry-run)
/// and by `GET /items/bulk-actions/jobs/:id`.
///
/// ``ItemsNamespace/bulkAction(_:options:)`` resolves with the embedded
/// ``BulkActionResult`` once `status` reaches a terminal value;
/// advanced callers using ``ItemsNamespace/bulkActionAsync(_:)`` get
/// the envelope directly and drive their own polling via
/// ``ItemsNamespace/bulkActionStatus(jobId:)``.
public struct BulkActionJob: Codable, Sendable {
    public let id: String
    public let action: String
    public let status: BulkActionJobStatus
    public let matched: Int
    public let processed: Int
    public let succeeded: Int
    public let errored: Int
    public let startedAt: String?
    public let finishedAt: String?
    /// Set when `status == .failed`.
    public let error: String?
    /// Set when `status == .completed`. Absent on `cancelled` — the
    /// envelope's `processed` / `succeeded` / `errored` fields carry
    /// the partial-progress state in that case.
    public let result: BulkActionResult?

    enum CodingKeys: String, CodingKey {
        case id, action, status, matched, processed, succeeded, errored
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case error, result
    }
}
