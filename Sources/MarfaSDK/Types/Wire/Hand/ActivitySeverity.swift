/// Surfacing level for `system.activity` items.
///
/// - ``info``: routine completion (a sync run finished cleanly). No user
///   attention required.
/// - ``warning``: non-blocking concern (a single record skipped, transient
///   rate limit). Surfaced in feed-style views but not in inboxes.
/// - ``error``: recoverable failure that the connector itself will retry.
///   Surfaced for visibility, not for action.
/// - ``actionRequired``: the user has to do something — re-authorize a
///   connection, resolve a tombstone conflict, etc. Surfaced as a
///   Repairs-style inbox via `/items?type=system.activity&filter=metadata.severity="action_required"`.
///
/// Wire spelling for ``actionRequired`` is `action_required`; the
/// CodingKeys-free Swift case adopts camelCase via an explicit raw value.
public enum ActivitySeverity: String, Codable, Sendable, Hashable, CaseIterable {
    case info
    case warning
    case error
    case actionRequired = "action_required"
}
