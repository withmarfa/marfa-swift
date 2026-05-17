import Foundation

/// Tenant-level configuration. Carries the three optional
/// schema-enforcement levers under ``enforcement`` plus the optional
/// per-tenant cleanup-job overrides that take precedence over the
/// instance env defaults.
///
/// PUT semantics are full-replacement: send the entire shape you want
/// persisted. An empty payload (`{}`) clears every override and reverts
/// to env defaults. The same shape is returned by `GET` and written by
/// `PUT`.
public struct TenantConfig: Codable, Sendable, Hashable {
    /// Schema-enforcement levers (TSC42 §5). See ``TenantConfig/Enforcement``.
    public var enforcement: Enforcement?

    /// Override for the audit-log retention window. `nil` falls back to
    /// the instance env default. Minimum `0` (no retention).
    public var auditRetentionDays: Int?

    /// Override for the event-log retention window in hours. `nil` falls
    /// back to the instance env default. Minimum `0`.
    public var eventLogRetentionHours: Int?

    /// Override for the trashed-item retention window in days. `nil`
    /// falls back to the instance env default. Minimum `0`.
    public var trashRetentionDays: Int?

    public init(
        enforcement: Enforcement? = nil,
        auditRetentionDays: Int? = nil,
        eventLogRetentionHours: Int? = nil,
        trashRetentionDays: Int? = nil
    ) {
        self.enforcement = enforcement
        self.auditRetentionDays = auditRetentionDays
        self.eventLogRetentionHours = eventLogRetentionHours
        self.trashRetentionDays = trashRetentionDays
    }

    enum CodingKeys: String, CodingKey {
        case enforcement
        case auditRetentionDays = "audit_retention_days"
        case eventLogRetentionHours = "event_log_retention_hours"
        case trashRetentionDays = "trash_retention_days"
    }

    /// Schema-enforcement configuration. Each lever is independent; any
    /// or all may be omitted.
    public struct Enforcement: Codable, Sendable, Hashable {
        /// Types listed here must validate against their registered
        /// schema. Items that fail validation are rejected at write
        /// time. Unlisted types are not enforced.
        public var strictMode: StrictMode?

        /// Source-allowlist policy — only sources listed in
        /// ``SourceAllowlist/sources`` may write items of the listed
        /// types. Use to lock a type to one connection.
        public var sourceAllowlist: SourceAllowlist?

        /// Source-filter policy — sources listed in
        /// ``SourceFilter/sources`` are blocked from writing items of
        /// the listed types. The inverse of ``sourceAllowlist``.
        public var sourceFilter: SourceFilter?

        public init(
            strictMode: StrictMode? = nil,
            sourceAllowlist: SourceAllowlist? = nil,
            sourceFilter: SourceFilter? = nil
        ) {
            self.strictMode = strictMode
            self.sourceAllowlist = sourceAllowlist
            self.sourceFilter = sourceFilter
        }

        enum CodingKeys: String, CodingKey {
            case strictMode = "strict_mode"
            case sourceAllowlist = "source_allowlist"
            case sourceFilter = "source_filter"
        }

        public struct StrictMode: Codable, Sendable, Hashable {
            /// Type IDs that must validate against their schema.
            public var types: [String]

            public init(types: [String]) {
                self.types = types
            }
        }

        public struct SourceAllowlist: Codable, Sendable, Hashable {
            /// Type IDs the allowlist applies to.
            public var types: [String]

            /// Source values permitted to write items of the listed types.
            public var sources: [String]

            public init(types: [String], sources: [String]) {
                self.types = types
                self.sources = sources
            }
        }

        public struct SourceFilter: Codable, Sendable, Hashable {
            /// Type IDs the filter applies to.
            public var types: [String]

            /// Source values blocked from writing items of the listed
            /// types.
            public var sources: [String]

            public init(types: [String], sources: [String]) {
                self.types = types
                self.sources = sources
            }
        }
    }
}
