import Foundation

/// A type schema defining the shape, states, and transitions for a Myme item type.
public struct TypeSchema: Codable, Sendable {
    public let id: String
    public let parent: String?
    public let label: String?
    public let description: String?
    public let version: Int
    public let fields: [String: FieldDefinition]
    public let states: [ItemState]
    public let defaultState: ItemState
    public let transitions: [String: [ItemState]]
    public let versionPolicy: VersionPolicy?

    enum CodingKeys: String, CodingKey {
        case id, parent, label, description, version, fields, states, transitions
        case defaultState = "default_state"
        case versionPolicy = "version_policy"
    }
}

/// Version retention policy overrides for a type.
public struct VersionPolicy: Codable, Sendable {
    public let recentDays: Int?
    public let dailySnapshotDays: Int?
    public let weeklySnapshotDays: Int?
    public let maxVersions: Int?

    enum CodingKeys: String, CodingKey {
        case recentDays = "recent_days"
        case dailySnapshotDays = "daily_snapshot_days"
        case weeklySnapshotDays = "weekly_snapshot_days"
        case maxVersions = "max_versions"
    }
}
