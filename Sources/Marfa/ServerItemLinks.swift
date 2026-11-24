import Foundation

/// The two addresses the server gives one item.
///
/// The server works both out each time it answers the item and stores neither.
public struct ItemLinks: Sendable, Hashable {
    /// The item's page at the instance's sign-in address, to share.
    ///
    /// It changes when the sign-in address moves.
    public let web: URL
    /// The item's address for apps on one device.
    ///
    /// It is `marfa://`, the instance's ID, then the item's ID, and stays the same when the sign-in address moves.
    public let app: URL

    public init(web: URL, app: URL) {
        self.web = web
        self.app = app
    }
}

extension Server {
    /// The web and app links of the item `id`, as the server answers them now.
    ///
    /// This only reads: it writes nothing, and the app and the working copy keep nothing from it. An item in Recently
    /// Deleted answers too. `id` must be a lowercase UUIDv7, the form of an item's ID; any other text throws
    /// ``MarfaError/invalid(message:)`` before a request is sent. The server answers an item it cannot read, or one
    /// that does not exist, with ``MarfaError/notFound(code:message:server:)``. Calls read the key this server
    /// holds, as a working copy does.
    ///
    /// An answer whose web link is not an `http` or `https` address with a host, or whose app link is not a `marfa://`
    /// address, throws ``MarfaError/decoding(message:)``.
    public func itemLinks(of id: String, timeout: Duration = Server.defaultTimeout) async throws(MarfaError)
        -> ItemLinks
    {
        guard Server.isItemID(id) else {
            throw .invalid(message: "an item's ID is a lowercase UUIDv7")
        }
        let data = try await send(
            "GET", "/items/\(Server.segment(id))", query: [URLQueryItem(name: "state", value: "any")],
            timeout: timeout)
        let wire: ItemLinksWire = try decode(data)
        guard let web = URL(string: wire.item.webUrl), let scheme = web.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = web.host(), !host.isEmpty,
            let app = URL(string: wire.item.appUrl), app.scheme?.lowercased() == "marfa"
        else {
            throw .decoding(message: "\(origin) answered an item's links in a form this build cannot read")
        }
        return ItemLinks(web: web, app: app)
    }

    private static func isItemID(_ text: String) -> Bool {
        text.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil
    }
}

private struct ItemLinksWire: Decodable {
    struct Item: Decodable {
        let webUrl: String
        let appUrl: String
        enum CodingKeys: String, CodingKey {
            case webUrl = "web_url"
            case appUrl = "app_url"
        }
    }
    let item: Item
}
