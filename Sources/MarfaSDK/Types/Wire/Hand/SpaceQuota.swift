import Foundation

/// Per-space quota row — `nil` fields fall back to the env defaults
/// (`MARFA_DEFAULT_QUOTA_*`). ``updatedAt`` is non-`nil` only when an
/// override row exists.
///
/// Returned by every quota read path:
/// - `client.spaces.quotas.getOwn()` — a credential holding `space.usage`,
///   reading its own space's row
/// - `client.spaces.quotas.getById(_:)` — the operator key, reading a named
///   space
/// - `client.spaces.quotas.set(id:_:)` — the operator key, writing one
public struct SpaceQuota: Codable, Sendable, Hashable {
    public let spaceId: String
    public let itemsLimit: Int?
    public let webhooksLimit: Int?
    public let blobsLimit: Int?
    public let storageBytesLimit: Int?
    public let ratePerMinuteLimit: Int?
    public let updatedAt: String?

    public init(
        spaceId: String,
        itemsLimit: Int?,
        webhooksLimit: Int?,
        blobsLimit: Int?,
        storageBytesLimit: Int?,
        ratePerMinuteLimit: Int?,
        updatedAt: String?
    ) {
        self.spaceId = spaceId
        self.itemsLimit = itemsLimit
        self.webhooksLimit = webhooksLimit
        self.blobsLimit = blobsLimit
        self.storageBytesLimit = storageBytesLimit
        self.ratePerMinuteLimit = ratePerMinuteLimit
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case spaceId = "space_id"
        case itemsLimit = "items_limit"
        case webhooksLimit = "webhooks_limit"
        case blobsLimit = "blobs_limit"
        case storageBytesLimit = "storage_bytes_limit"
        case ratePerMinuteLimit = "rate_per_minute_limit"
        case updatedAt = "updated_at"
    }
}

/// Body for `PUT /spaces/{id}/quotas`. Each field is independent — a
/// supplied non-`nil` value overrides the env default; an explicit `nil`
/// resets that field to the env default. Field omission (no value at all)
/// leaves the existing override untouched.
public struct SpaceQuotaInput: Codable, Sendable, Hashable {
    public var itemsLimit: Int?
    public var webhooksLimit: Int?
    public var blobsLimit: Int?
    public var storageBytesLimit: Int?
    public var ratePerMinuteLimit: Int?

    public init(
        itemsLimit: Int? = nil,
        webhooksLimit: Int? = nil,
        blobsLimit: Int? = nil,
        storageBytesLimit: Int? = nil,
        ratePerMinuteLimit: Int? = nil
    ) {
        self.itemsLimit = itemsLimit
        self.webhooksLimit = webhooksLimit
        self.blobsLimit = blobsLimit
        self.storageBytesLimit = storageBytesLimit
        self.ratePerMinuteLimit = ratePerMinuteLimit
    }

    enum CodingKeys: String, CodingKey {
        case itemsLimit = "items_limit"
        case webhooksLimit = "webhooks_limit"
        case blobsLimit = "blobs_limit"
        case storageBytesLimit = "storage_bytes_limit"
        case ratePerMinuteLimit = "rate_per_minute_limit"
    }
}
