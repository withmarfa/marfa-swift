import Foundation

/// One earlier state of an item, as the server keeps it.
///
/// A working copy keeps no history, so a snapshot is read from the server and needs a connection.
public struct ItemSnapshot: Sendable, Hashable, Identifiable {
    /// Who or what made the write that replaced this state.
    public struct Writer: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// The owner's browser.
            case browser
            /// An app the owner approved.
            case app
            /// An API key.
            case key
            /// The local command on the server's machine.
            case local
            /// A kind of sign-in this build does not know, as the server names it.
            case other(String)

            public init(rawValue: String) {
                switch rawValue {
                case "browser": self = .browser
                case "app": self = .app
                case "key": self = .key
                case "local": self = .local
                default: self = .other(rawValue)
                }
            }

            /// The kind as the server names it.
            public var rawValue: String {
                switch self {
                case .browser: "browser"
                case .app: "app"
                case .key: "key"
                case .local: "local"
                case .other(let name): name
                }
            }
        }

        public let kind: Kind
        public let id: String
        public let name: String

        public init(kind: Kind, id: String, name: String) {
            self.kind = kind
            self.id = id
            self.name = name
        }
    }

    public let id: String
    public let itemID: String
    /// The item's version number at this snapshot, counting up from 1.
    public let version: Int
    public let type: String
    public let tier: Tier
    /// The properties the item held before the write that replaced them.
    public let properties: JSONObject
    /// The `occurred_at` the item had at this version.
    public let occurredAt: ItemDate?
    public let sourceID: String?
    /// The sign-in that made the write, or `nil` where the server recorded none, as for a change the server made
    /// itself.
    public let writer: Writer?
    /// When the snapshot was taken, which is when the write that replaced this state happened.
    public let createdAt: Date

    public init(
        id: String, itemID: String, version: Int, type: String, tier: Tier, properties: JSONObject,
        occurredAt: ItemDate?, sourceID: String?, writer: Writer?, createdAt: Date
    ) {
        self.id = id
        self.itemID = itemID
        self.version = version
        self.type = type
        self.tier = tier
        self.properties = properties
        self.occurredAt = occurredAt
        self.sourceID = sourceID
        self.writer = writer
        self.createdAt = createdAt
    }
}

/// One page of an item's snapshots, oldest first.
public struct ItemSnapshotPage: Sendable, Hashable {
    public let snapshots: [ItemSnapshot]
    /// Pass this as `after` to read the next page; `nil` on the last page.
    ///
    /// A page can be short, or empty, with more to follow, so stop only when this is `nil`.
    public let next: String?

    public init(snapshots: [ItemSnapshot], next: String?) {
        self.snapshots = snapshots
        self.next = next
    }
}

/// A change to one setting: a new value, or the removal of the value so the server's default applies.
public enum SettingChange<Value: Sendable & Hashable>: Sendable, Hashable {
    case set(Value)
    case clear
}

/// The settings of the Marfa server itself.
///
/// A setting the server has no value for, so its default applies, is `nil`. The instance's enforcement levers are
/// not part of this value.
public struct InstanceConfig: Sendable, Hashable {
    /// Names the instance; sent with a change, so a change that reaches another instance at the same address is
    /// refused where it lands.
    public var instanceID: String
    public var name: String?
    public var trashRetentionDays: Int?
    public var versionRecentDays: Int?
    public var versionDailySnapshotDays: Int?
    public var versionWeeklySnapshotDays: Int?
    public var versionMaxVersions: Int?
    public var grantInactivityDays: Int?
    public var auditRetentionDays: Int?
    public var eventLogRetentionHours: Int?
    /// Days the server keeps inbound webhook deliveries a connector has marked handled; `0` keeps them with no age
    /// limit.
    public var inboundHandledRetentionDays: Int?
    /// Days the server keeps inbound webhook deliveries no connector has marked handled; `0` keeps them with no age
    /// limit.
    public var inboundPendingRetentionDays: Int?
    public var enrichmentEnabled: Bool?
    public var enrichmentOCREnabled: Bool?
    public var errorReportingEnabled: Bool?
    public var heartbeatEnabled: Bool?

    public init(
        instanceID: String, name: String? = nil, trashRetentionDays: Int? = nil, versionRecentDays: Int? = nil,
        versionDailySnapshotDays: Int? = nil, versionWeeklySnapshotDays: Int? = nil, versionMaxVersions: Int? = nil,
        grantInactivityDays: Int? = nil, auditRetentionDays: Int? = nil, eventLogRetentionHours: Int? = nil,
        inboundHandledRetentionDays: Int? = nil, inboundPendingRetentionDays: Int? = nil,
        enrichmentEnabled: Bool? = nil, enrichmentOCREnabled: Bool? = nil, errorReportingEnabled: Bool? = nil,
        heartbeatEnabled: Bool? = nil
    ) {
        self.instanceID = instanceID
        self.name = name
        self.trashRetentionDays = trashRetentionDays
        self.versionRecentDays = versionRecentDays
        self.versionDailySnapshotDays = versionDailySnapshotDays
        self.versionWeeklySnapshotDays = versionWeeklySnapshotDays
        self.versionMaxVersions = versionMaxVersions
        self.grantInactivityDays = grantInactivityDays
        self.auditRetentionDays = auditRetentionDays
        self.eventLogRetentionHours = eventLogRetentionHours
        self.inboundHandledRetentionDays = inboundHandledRetentionDays
        self.inboundPendingRetentionDays = inboundPendingRetentionDays
        self.enrichmentEnabled = enrichmentEnabled
        self.enrichmentOCREnabled = enrichmentOCREnabled
        self.errorReportingEnabled = errorReportingEnabled
        self.heartbeatEnabled = heartbeatEnabled
    }
}

/// The settings to change; a field left `nil` is not sent, so the server keeps it as it is.
public struct InstanceConfigPatch: Sendable, Hashable {
    public var name: SettingChange<String>?
    public var trashRetentionDays: SettingChange<Int>?
    public var versionRecentDays: SettingChange<Int>?
    public var versionDailySnapshotDays: SettingChange<Int>?
    public var versionWeeklySnapshotDays: SettingChange<Int>?
    public var versionMaxVersions: SettingChange<Int>?
    public var grantInactivityDays: SettingChange<Int>?
    public var auditRetentionDays: SettingChange<Int>?
    public var eventLogRetentionHours: SettingChange<Int>?
    public var inboundHandledRetentionDays: SettingChange<Int>?
    public var inboundPendingRetentionDays: SettingChange<Int>?
    public var enrichmentEnabled: SettingChange<Bool>?
    public var enrichmentOCREnabled: SettingChange<Bool>?
    public var errorReportingEnabled: SettingChange<Bool>?
    public var heartbeatEnabled: SettingChange<Bool>?

    public init() {}

    var body: [String: Any] {
        var body: [String: Any] = [:]
        func put<V>(_ key: String, _ change: SettingChange<V>?) {
            switch change {
            case .set(let value)?: body[key] = value
            case .clear?: body[key] = NSNull()
            case nil: break
            }
        }
        put("name", name)
        put("trash_retention_days", trashRetentionDays)
        put("version_recent_days", versionRecentDays)
        put("version_daily_snapshot_days", versionDailySnapshotDays)
        put("version_weekly_snapshot_days", versionWeeklySnapshotDays)
        put("version_max_versions", versionMaxVersions)
        put("grant_inactivity_days", grantInactivityDays)
        put("audit_retention_days", auditRetentionDays)
        put("event_log_retention_hours", eventLogRetentionHours)
        put("inbound_handled_retention_days", inboundHandledRetentionDays)
        put("inbound_pending_retention_days", inboundPendingRetentionDays)
        put("enrichment_enabled", enrichmentEnabled)
        put("enrichment_ocr_enabled", enrichmentOCREnabled)
        put("error_reporting_enabled", errorReportingEnabled)
        put("heartbeat_enabled", heartbeatEnabled)
        return body
    }
}

extension Server {
    /// How long a call may take in all before it throws ``MarfaError/network(message:)``.
    ///
    /// An unreachable or stalled server then never leaves an app waiting. The limit covers renewing a refused
    /// access token and sending again.
    public static let defaultTimeout = Duration.seconds(20)

    /// The snapshots of the item `id`, oldest first, one page at a time.
    ///
    /// Pass the previous page's ``ItemSnapshotPage/next`` as `after` for the following page. `limit` is 1 to 200;
    /// the server's default applies when it is `nil`. The server answers an item it cannot read, in the trash or of
    /// a type the key does not reach, with ``MarfaError/notFound(code:message:)``. Calls read the key this server
    /// holds, as a working copy does.
    ///
    /// A snapshot whose `created_at` this build cannot read makes the whole page throw
    /// ``MarfaError/decoding(message:)`` rather than leave the snapshot out, which would show the item's history with
    /// a version missing. The server records that time itself, so only a server writing it in another form does this.
    public func snapshots(
        ofItem id: String, after cursor: String? = nil, limit: Int? = nil, timeout: Duration = Server.defaultTimeout
    ) async throws(MarfaError) -> ItemSnapshotPage {
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await send(
            "GET", "/items/\(Server.segment(id))/versions", query: query, timeout: timeout)
        let page: SnapshotPageWire = try decode(data)
        var snapshots: [ItemSnapshot] = []
        for wire in page.data { snapshots.append(try snapshot(wire)) }
        return ItemSnapshotPage(snapshots: snapshots, next: page.nextCursor)
    }

    /// The server's settings.
    ///
    /// Needs the `config.manage` permission, else throws ``MarfaError/forbidden(code:message:)``.
    public func config(timeout: Duration = Server.defaultTimeout) async throws(MarfaError) -> InstanceConfig {
        InstanceConfig(try decode(try await send("GET", "/config", timeout: timeout)) as InstanceConfigWire)
    }

    /// Changes the settings in `patch` and answers the settings as stored.
    ///
    /// Only the fields set on `patch` are sent. `instanceID`, from an earlier ``config(timeout:)``, makes the server
    /// refuse the change with ``MarfaError/instanceChanged(message:)`` when the address now reaches another instance.
    public func updateConfig(
        _ patch: InstanceConfigPatch, expecting instanceID: String? = nil, timeout: Duration = Server.defaultTimeout
    ) async throws(MarfaError) -> InstanceConfig {
        guard let body = try? JSONSerialization.data(withJSONObject: patch.body, options: [.sortedKeys]) else {
            throw .invalid(message: "the settings could not be written as json")
        }
        let headers = instanceID.map { ["X-Marfa-Instance-Id": $0] } ?? [:]
        let answer: InstanceConfigWire = try decode(
            try await send("PATCH", "/config", headers: headers, body: body, timeout: timeout))
        return InstanceConfig(answer)
    }

    /// Sets or, with `nil`, removes the owner's icon for the item type `id`, and answers the icon the type has now.
    ///
    /// The type can be one Marfa ships. Removing the owner's icon shows the author's again.
    ///
    /// `icon` is an Iconify ID, `<set>:<name>`, from a set Marfa pins: `lucide:book-open`, or `simple-icons:github`
    /// for a brand mark. The server refuses any other with ``MarfaError/validation(code:message:)`` and the code
    /// `invalid_schema`. Needs `schema.write` and write on the type. A working copy's `catalog` takes the change
    /// when its server stream next reopens, so another device shows it within about two minutes.
    @discardableResult
    public func setTypeIcon(
        _ icon: String?, ofType id: String, expecting instanceID: String? = nil,
        timeout: Duration = Server.defaultTimeout
    ) async throws(MarfaError) -> String? {
        let path = "/types/\(Server.segment(id))/icon"
        let headers = instanceID.map { ["X-Marfa-Instance-Id": $0] } ?? [:]
        let data: Data
        if let icon {
            guard let body = try? JSONSerialization.data(withJSONObject: ["icon": icon]) else {
                throw .invalid(message: "the icon could not be written as json")
            }
            data = try await send("PUT", path, headers: headers, body: body, timeout: timeout)
        } else {
            data = try await send("DELETE", path, headers: headers, timeout: timeout)
        }
        let answer: TypeWire = try decode(data)
        return answer.type.displayHints?.icon
    }

    private func decode<T: Decodable>(_ data: Data) throws(MarfaError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decoding(message: "\(origin) answered in a form this build cannot read")
        }
    }

    private func snapshot(_ wire: SnapshotWire) throws(MarfaError) -> ItemSnapshot {
        guard let created = ItemDate.parse(wire.createdAt)?.date else {
            throw .decoding(message: "\(origin) answered a snapshot with a time this build cannot read")
        }
        return ItemSnapshot(
            id: wire.id, itemID: wire.itemId, version: wire.version, type: wire.type,
            tier: wire.tier == "feed" ? .feed : .library, properties: wire.properties,
            occurredAt: ItemDate.parse(wire.occurredAt), sourceID: wire.sourceId,
            writer: wire.writer.map { .init(kind: .init(rawValue: $0.kind), id: $0.id, name: $0.name) },
            createdAt: created)
    }
}

private struct SnapshotPageWire: Decodable {
    let data: [SnapshotWire]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case data
        case nextCursor = "next_cursor"
    }
}

private struct SnapshotWire: Decodable {
    struct Writer: Decodable {
        let kind: String
        let id: String
        let name: String
    }
    let id: String
    let itemId: String
    let version: Int
    let properties: JSONObject
    let type: String
    let tier: String
    let occurredAt: String
    let sourceId: String?
    let writer: Writer?
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, version, properties, type, tier, writer
        case itemId = "item_id"
        case occurredAt = "occurred_at"
        case sourceId = "source_id"
        case createdAt = "created_at"
    }
}

private struct TypeWire: Decodable {
    struct Definition: Decodable {
        struct Hints: Decodable { let icon: String? }
        let displayHints: Hints?
        enum CodingKeys: String, CodingKey { case displayHints = "display_hints" }
    }
    let type: Definition
}

private struct InstanceConfigWire: Decodable {
    let instanceId: String
    let name: String?
    let trashRetentionDays: Int?
    let versionRecentDays: Int?
    let versionDailySnapshotDays: Int?
    let versionWeeklySnapshotDays: Int?
    let versionMaxVersions: Int?
    let grantInactivityDays: Int?
    let auditRetentionDays: Int?
    let eventLogRetentionHours: Int?
    let inboundHandledRetentionDays: Int?
    let inboundPendingRetentionDays: Int?
    let enrichmentEnabled: Bool?
    let enrichmentOcrEnabled: Bool?
    let errorReportingEnabled: Bool?
    let heartbeatEnabled: Bool?
    enum CodingKeys: String, CodingKey {
        case instanceId = "instance_id"
        case name
        case trashRetentionDays = "trash_retention_days"
        case versionRecentDays = "version_recent_days"
        case versionDailySnapshotDays = "version_daily_snapshot_days"
        case versionWeeklySnapshotDays = "version_weekly_snapshot_days"
        case versionMaxVersions = "version_max_versions"
        case grantInactivityDays = "grant_inactivity_days"
        case auditRetentionDays = "audit_retention_days"
        case eventLogRetentionHours = "event_log_retention_hours"
        case inboundHandledRetentionDays = "inbound_handled_retention_days"
        case inboundPendingRetentionDays = "inbound_pending_retention_days"
        case enrichmentEnabled = "enrichment_enabled"
        case enrichmentOcrEnabled = "enrichment_ocr_enabled"
        case errorReportingEnabled = "error_reporting_enabled"
        case heartbeatEnabled = "heartbeat_enabled"
    }
}

extension InstanceConfig {
    fileprivate init(_ wire: InstanceConfigWire) {
        self.init(
            instanceID: wire.instanceId, name: wire.name, trashRetentionDays: wire.trashRetentionDays,
            versionRecentDays: wire.versionRecentDays, versionDailySnapshotDays: wire.versionDailySnapshotDays,
            versionWeeklySnapshotDays: wire.versionWeeklySnapshotDays, versionMaxVersions: wire.versionMaxVersions,
            grantInactivityDays: wire.grantInactivityDays, auditRetentionDays: wire.auditRetentionDays,
            eventLogRetentionHours: wire.eventLogRetentionHours,
            inboundHandledRetentionDays: wire.inboundHandledRetentionDays,
            inboundPendingRetentionDays: wire.inboundPendingRetentionDays, enrichmentEnabled: wire.enrichmentEnabled,
            enrichmentOCREnabled: wire.enrichmentOcrEnabled, errorReportingEnabled: wire.errorReportingEnabled,
            heartbeatEnabled: wire.heartbeatEnabled)
    }
}
