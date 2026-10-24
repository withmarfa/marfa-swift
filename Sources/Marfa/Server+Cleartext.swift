import Foundation
import Synchronization

/// What an app tells a person whose key is about to travel over plain http to another host.
///
/// The package shows nothing itself. An app shows `title` and `message` in its own alert, once.
public struct PlainHTTPNotice: Sendable, Hashable, Identifiable {
    /// The scheme, host and port the key is sent to, and nothing else of the address.
    public let origin: String

    public var id: String { origin }

    public var title: String { "This connection is not encrypted" }

    public var message: String {
        "Your key is sent to \(origin) over plain http, so anyone on the network can read it. "
            + "Use an https address unless this network is private and you meant this."
    }
}

extension Server {
    /// Whether the address is plain http on a host other than this machine, so a key sent to it can be read on
    /// the way.
    ///
    /// The rule is the command line's. `https`, `localhost`, any address in `127.0.0.0/8` and `::1` are not; every
    /// other host name and address is, including an IPv4-mapped IPv6 address such as `::ffff:127.0.0.1`.
    public var isPlainHTTPToAnotherHost: Bool {
        origin != nil
    }

    /// The notice for this address the first time any server with the same origin asks in this process, and `nil`
    /// every time after, for `https`, and for the machine itself.
    ///
    /// Call it where the app first opens a copy or signs in on the server, and show what it returns.
    public func takePlainHTTPNotice() -> PlainHTTPNotice? {
        guard let origin, Self.noticed.withLock({ $0.insert(origin).inserted }) else { return nil }
        return PlainHTTPNotice(origin: origin)
    }

    private static let noticed = Mutex<Set<String>>([])

    /// The origin of a plain http address on another host, as the command line names it in its warning.
    private var origin: String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "http", var host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !Self.isLoopback(host) else { return nil }
        let shown = host.contains(":") ? "[\(host)]" : host
        let port = components.port.flatMap { $0 == 80 ? nil : ":\($0)" } ?? ""
        return "http://\(shown)\(port)"
    }

    /// `localhost`, `127.0.0.0/8` and `::1`.
    ///
    /// An IPv4 address is read as the command line's URL parser reads it, so `127.1` is loopback too.
    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" { return true }
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        return withUnsafeBytes(of: v6) { Array($0) } == [UInt8](repeating: 0, count: 15) + [1]
    }
}
