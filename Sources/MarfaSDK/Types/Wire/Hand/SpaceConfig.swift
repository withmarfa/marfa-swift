import Foundation

/// Space-level configuration. Carries the schema-enforcement levers under
/// ``enforcement``, the event hop budget, and the per-space cleanup-job
/// overrides that take precedence over the instance env defaults.
///
/// PUT semantics are full-replacement: send the entire shape you want
/// persisted. An empty payload (`{}`) clears every override and reverts
/// to env defaults. The same shape is returned by `GET` and written by
/// `PUT`.
///
/// Every field the platform declares has to appear here for that to be
/// safe. A field this struct does not know is dropped silently on decode,
/// so a read, change one value, write it back would erase whatever the
/// space had set for it, and report success. Two were missing and did
/// exactly that.
public struct SpaceConfig: Codable, Sendable, Hashable {
    /// Schema-enforcement levers. See ``SpaceConfig/Enforcement``.
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

    /// Override for the activity-row retention window in days. `nil`
    /// falls back to the instance env default. Minimum `0`.
    public var activityRetentionDays: Int?

    /// How many hops one event may travel before the bus drops it as a
    /// suspected cycle. `nil` falls back to the instance default. `0`
    /// stops integration-originated events propagating at all; writes a
    /// person makes are never subject to it. Accepted range `0...100`.
    public var maxEventHopBudget: Int?

    public init(
        enforcement: Enforcement? = nil,
        auditRetentionDays: Int? = nil,
        eventLogRetentionHours: Int? = nil,
        trashRetentionDays: Int? = nil,
        activityRetentionDays: Int? = nil,
        maxEventHopBudget: Int? = nil
    ) {
        self.enforcement = enforcement
        self.auditRetentionDays = auditRetentionDays
        self.eventLogRetentionHours = eventLogRetentionHours
        self.trashRetentionDays = trashRetentionDays
        self.activityRetentionDays = activityRetentionDays
        self.maxEventHopBudget = maxEventHopBudget
    }

    enum CodingKeys: String, CodingKey {
        case enforcement
        case auditRetentionDays = "audit_retention_days"
        case eventLogRetentionHours = "event_log_retention_hours"
        case trashRetentionDays = "trash_retention_days"
        case activityRetentionDays = "activity_retention_days"
        case maxEventHopBudget = "max_event_hop_budget"
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

        /// Source-filter policy, applied on read rather than on write. A
        /// row whose type is listed here is returned only when its source
        /// is one of ``SourceFilter/sources``; every other row passes
        /// untouched. The listed sources are the approved ones.
        ///
        /// Not the inverse of ``sourceAllowlist``, which is the write-side
        /// lever: that one refuses a write whose credential source is not
        /// listed. Setting this one expecting the other hides every item
        /// of those types from every other source, which looks like data
        /// loss and is silent.
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

            /// The approved sources. A row of one of the listed types is
            /// returned by a read only when its source appears here, so an
            /// empty list hides every row of those types. This is a read
            /// filter, not a write rule: it never refuses a write, and it
            /// is not the list of sources to block.
            public var sources: [String]

            public init(types: [String], sources: [String]) {
                self.types = types
                self.sources = sources
            }
        }
    }
}
