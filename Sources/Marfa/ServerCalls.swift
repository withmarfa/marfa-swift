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
    /// a type the key does not reach, with ``MarfaError/notFound(code:message:server:)``. Calls read the key this server
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

    /// Sets or, with `nil`, removes the owner's icon for the item type `id`, and answers the icon the type has now.
    ///
    /// The type can be one Marfa ships. Removing the owner's icon shows the author's again.
    ///
    /// `icon` is an Iconify ID, `<set>:<name>`, from a set Marfa pins: `lucide:book-open`, or `simple-icons:github`
    /// for a brand mark. The server refuses any other with ``MarfaError/validation(code:message:details:server:)`` and the code
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
        return answer.displayHints?.icon
    }

    func decode<T: Decodable>(_ data: Data) throws(MarfaError) -> T {
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
    struct Hints: Decodable { let icon: String? }
    let displayHints: Hints?
    enum CodingKeys: String, CodingKey { case displayHints = "display_hints" }
}
