import Foundation

/// Typed wrapper for `system.activity` items — user-meaningful telemetry
/// emitted by integrations at semantic boundaries (sync runs, errors,
/// reauth prompts).
///
/// ``severity`` drives surfacing:
/// - ``ActivitySeverity/info``: routine completion.
/// - ``ActivitySeverity/warning``: non-blocking concern.
/// - ``ActivitySeverity/error``: recoverable failure (the integration
///   itself will retry).
/// - ``ActivitySeverity/actionRequired``: the user has to do something —
///   surfaced as a Repairs-style inbox via
///   `metadata.severity="action_required"`.
///
/// Per-Connection feed-eligibility lives on the emitting
/// ``Connection/feedActivity``; when true, server stamps `tier:'feed'`
/// on activity items the connection writes.
public struct Activity: MarfaItem {
    public static let typeIdentifier = "system.activity"

    public let item: Item

    /// Id of the emitting `system.connection` item.
    public var connectionId: String {
        item.properties["connection_id"]?.stringValue ?? ""
    }

    /// Surfacing level.
    public var severity: ActivitySeverity {
        guard let raw = item.properties["severity"]?.stringValue,
              let value = ActivitySeverity(rawValue: raw) else {
            return .info
        }
        return value
    }

    /// Short one-liner shown in feed surfaces.
    public var summary: String {
        item.properties["summary"]?.stringValue ?? ""
    }

    /// Optional JSON context for richer rendering or programmatic
    /// resolution.
    public var detail: [String: JSONValue]? {
        item.properties["detail"]?.dictionaryValue
    }

    public init?(from item: Item) {
        guard item.type == Self.typeIdentifier else { return nil }
        guard item.properties["connection_id"]?.stringValue != nil else { return nil }
        guard item.properties["severity"]?.stringValue != nil else { return nil }
        guard item.properties["summary"]?.stringValue != nil else { return nil }
        self.item = item
    }

    public func toProperties() -> [String: JSONValue] {
        item.properties
    }
}
