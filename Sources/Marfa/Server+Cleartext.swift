import Foundation

extension Server {
    /// The origin of the address when it is plain http to a host other than this machine, so a key sent to it can
    /// be read on the way, and `nil` for `https` and for the machine itself.
    ///
    /// The origin is the scheme, host and port, as the command line names it in its warning, and nothing else of
    /// the address. An app that warns a person shows it, once for each origin if it chooses: the package holds no
    /// state and writes no words.
    ///
    /// The rule is the command line's. `https`, `localhost`, any address in `127.0.0.0/8` and `::1` have none; every
    /// other host name and address does, including an IPv4-mapped IPv6 address such as `::ffff:127.0.0.1`.
    public var plainHTTPOrigin: String? {
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
