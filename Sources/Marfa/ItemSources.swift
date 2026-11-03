import Foundation

/// A source: the code that says what wrote an item, with the name and mark to show it by.
///
/// A source's name and mark belong to the server, not to its items, so they are read and set with a connection and
/// a working copy holds neither.
public struct ItemSource: Sendable, Hashable, Identifiable {
    /// Where a source's ``name`` comes from.
    public enum NameOrigin: Sendable, Hashable {
        /// Set on the source with ``Server/updateSource(_:name:mark:timeout:)``.
        case set
        /// The name an app signed in to the server writes under this source with.
        case app
        /// The label of the key that holds the source as its own.
        case key
        /// Nothing names the source, so its code stands in.
        case code
        /// An origin this build does not know, as the server names it.
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "set": self = .set
            case "app": self = .app
            case "key": self = .key
            case "code": self = .code
            default: self = .other(rawValue)
            }
        }

        /// The origin as the server names it.
        public var rawValue: String {
            switch self {
            case .set: "set"
            case .app: "app"
            case .key: "key"
            case .code: "code"
            case .other(let name): name
            }
        }
    }

    /// The source code, as an item carries it in `source`.
    public let code: String
    /// The name to show for the source; never empty.
    public let name: String
    public let nameOrigin: NameOrigin
    /// The icon ID to draw beside the name, or `nil` where none is set.
    ///
    /// It comes from the sets a type's icon comes from (`lucide:` or `simple-icons:`); draw it with `TypeIcon(id:)`.
    public let mark: String?

    public var id: String { code }

    public init(code: String, name: String, nameOrigin: NameOrigin, mark: String? = nil) {
        self.code = code
        self.name = name
        self.nameOrigin = nameOrigin
        self.mark = mark
    }
}

extension Server {
    /// The sources this key can see, ordered by code.
    ///
    /// A key sees its own source, those it claims and those of items it can read. A key with `keys.manage` sees every
    /// source the instance holds.
    public func sources(timeout: Duration = Server.defaultTimeout) async throws(MarfaError) -> [ItemSource] {
        let page: SourcePageWire = try decode(try await send("GET", "/sources", timeout: timeout))
        return page.data.map(ItemSource.init)
    }

    /// The source `code`.
    ///
    /// Throws ``MarfaError/notFound(code:message:)`` for a source this key cannot see: not its own, not one it
    /// claims and carried by no item it can read, unless it holds `keys.manage`.
    public func source(_ code: String, timeout: Duration = Server.defaultTimeout) async throws(MarfaError) -> ItemSource
    {
        ItemSource(
            try decode(
                try await send("GET", "/source", query: [URLQueryItem(name: "source", value: code)], timeout: timeout))
                as SourceWire)
    }

    /// Changes the name or mark of the source `code` and answers the source as it now reads.
    ///
    /// A change left `nil` is not sent, so the server keeps that field; ``SettingChange/clear`` removes it, so the
    /// source shows the name its app or key gives it, or its code. A name is trimmed and is 1 to 200 characters
    /// with no control character; a mark is an Iconify ID from a set Marfa pins, as for ``setTypeIcon(_:ofType:expecting:timeout:)``.
    /// The server refuses a name with ``MarfaError/validation(code:message:details:)`` and the code
    /// `validation_error`, and a mark with `invalid_schema`, changing neither field.
    ///
    /// A key may change its own source and those it claims; any other needs `keys.manage`, else the call throws
    /// ``MarfaError/forbidden(code:message:)``.
    @discardableResult
    public func updateSource(
        _ code: String, name: SettingChange<String>? = nil, mark: SettingChange<String>? = nil,
        timeout: Duration = Server.defaultTimeout
    ) async throws(MarfaError) -> ItemSource {
        var fields: [String: Any] = [:]
        switch name {
        case .set(let value)?: fields["name"] = value
        case .clear?: fields["name"] = NSNull()
        case nil: break
        }
        switch mark {
        case .set(let value)?: fields["mark"] = value
        case .clear?: fields["mark"] = NSNull()
        case nil: break
        }
        guard let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            throw .invalid(message: "the source could not be written as json")
        }
        let answer: SourceWire = try decode(
            try await send(
                "PATCH", "/source", query: [URLQueryItem(name: "source", value: code)], body: body, timeout: timeout))
        return ItemSource(answer)
    }

    /// How many items each source wrote, as `GET /items/stats` counts them, keyed by source code.
    ///
    /// The count is the server's own, under the same filters as a listing: `type` is a type, a comma-separated list
    /// or a wildcard such as `core.*`; `state` is one lifecycle state or a comma-separated list, and without it every
    /// state is counted, the bin included; `tier` leaves out the other tier; `filter` is a filter expression. A
    /// source that wrote no matching item is absent. Items a key cannot read are not counted.
    public func itemCountsBySource(
        type: String? = nil, state: String? = nil, tier: Tier? = nil, filter: String? = nil,
        timeout: Duration = Server.defaultTimeout
    ) async throws(MarfaError) -> [String: Int] {
        var query = [URLQueryItem(name: "by", value: "source")]
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        if let state { query.append(URLQueryItem(name: "state", value: state)) }
        if let tier { query.append(URLQueryItem(name: "tier", value: tier == .feed ? "feed" : "library")) }
        if let filter { query.append(URLQueryItem(name: "filter", value: filter)) }
        return try decode(try await send("GET", "/items/stats", query: query, timeout: timeout))
    }
}

private struct SourceWire: Decodable {
    let source: String
    let name: String
    let nameFrom: String
    let mark: String?
    enum CodingKeys: String, CodingKey {
        case source, name, mark
        case nameFrom = "name_from"
    }
}

private struct SourcePageWire: Decodable {
    let data: [SourceWire]
}

extension ItemSource {
    fileprivate init(_ wire: SourceWire) {
        self.init(code: wire.source, name: wire.name, nameOrigin: .init(rawValue: wire.nameFrom), mark: wire.mark)
    }
}
