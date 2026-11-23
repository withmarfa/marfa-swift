import CryptoKit
import Foundation
import Marfa

/// A release version, `MAJOR.MINOR.PATCH`, compared by its numbers.
public struct PluginVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64

    public init(major: UInt64, minor: UInt64, patch: UInt64) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads three numbers joined by dots, none with a leading zero, and nothing else.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                part == "0" || !part.hasPrefix("0"), let number = UInt64(part)
            else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// Whether this is `0.0.0`, the release of a development build, which takes any plugin.
    public var isDevelopment: Bool { self == PluginVersion(major: 0, minor: 0, patch: 0) }

    /// Whether a server running this release takes a plugin whose oldest Marfa is `marfa`.
    public func takes(_ marfa: PluginVersion) -> Bool { isDevelopment || marfa <= self }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: PluginVersion, rhs: PluginVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A plugin the release lists.
public struct PluginIndexEntry: Sendable, Hashable, Identifiable {
    /// The plugin's name, which is also its `id`.
    public let name: String
    public let title: String
    public let description: String
    /// The icon the plugin is shown by, an Iconify ID.
    public let mark: String
    public let maker: String
    /// The oldest Marfa release the plugin works with.
    public let marfa: PluginVersion
    public let version: PluginVersion
    public let hasConnector: Bool
    /// The bundle's file name in the release.
    public let bundle: String
    /// The SHA-256 of the bundle's bytes, in hexadecimal, as the release lists it.
    public let sha256: String

    public var id: String { name }
}

/// What a plugin's bundle holds, for an app to draw a plugin that is not installed.
///
/// A key a build does not read is left out here and stays in the bundle's bytes.
public struct PluginBundleContents: Sendable, Hashable {
    public struct TypeDefinition: Sendable, Hashable {
        public let id: String
        public let label: String?
        public let description: String?
        public let parent: String?
        public let icon: String?
        /// The text that tells an agent when to use the type, which an app may not write.
        public let guidance: String?
    }

    public struct EdgeTypeDefinition: Sendable, Hashable {
        public let id: String
        public let label: String?
        public let reverseLabel: String?
        public let description: String?
    }

    public struct ConnectorDefinition: Sendable, Hashable {
        public struct Kind: Sendable, Hashable {
            public let name: String
            /// The ID of the type the kind is written as.
            public let type: String
            /// `in`, `out` or `both`.
            public let direction: String
        }

        public struct Setting: Sendable, Hashable {
            public let name: String
            public let label: String
            /// `text`, `number`, `boolean` or `choice`.
            public let kind: String
            public let isSecret: Bool
            public let isRequired: Bool
            public let choices: [String]
            public let defaultValue: JSONValue?
        }

        /// The source the connector writes under.
        public let source: String
        public let sourceName: String
        public let sourceMark: String?
        public let kinds: [Kind]
        public let settings: [Setting]
        public let edgeTypes: [String]
    }

    public let name: String
    public let title: String
    public let description: String
    public let mark: String
    public let maker: String
    public let marfa: PluginVersion
    public let version: PluginVersion
    public let types: [TypeDefinition]
    public let edgeTypes: [EdgeTypeDefinition]
    public let connector: ConnectorDefinition?
}

/// A bundle read from a release, whose bytes match the digest the release lists.
public struct ReleasedPlugin: Sendable, Hashable {
    public let entry: PluginIndexEntry
    /// The bundle's bytes as the release serves them.
    ///
    /// Install these, unchanged, with ``Server/install(pluginBundle:expecting:timeout:)`` so the server records the
    /// digest the release lists.
    public let bytes: Data
    public let contents: PluginBundleContents
}

/// Why a plugins release could not be read.
public enum PluginReleaseError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The address carries a user name or a password, which a request would send as a credential.
    case addressCarriesCredentials
    /// The address is not an `http` or `https` address with a host and no query or fragment.
    case addressUnreadable
    /// The release could not be read: the connection failed, a file was missing, or what it served was not what a
    /// release serves. `reason` says which.
    case unreachable(address: String, reason: String)
    /// The bundle's SHA-256 is not the one the release's index lists, so its bytes are not to be used.
    case digestMismatch(file: String, found: String, listed: String)
    /// The task was canceled.
    case canceled

    public var description: String {
        switch self {
        case .addressCarriesCredentials:
            "the plugins address carries a user name or password, which is never sent: use the release address alone"
        case .addressUnreadable:
            "the plugins address is not an http or https address with a host and no query or fragment"
        case .unreachable(let address, let reason): "the plugins release at \(address) could not be read: \(reason)"
        case .digestMismatch(let file, let found, let listed):
            "\(file) has the SHA-256 \(found), and the release's index lists \(listed)"
        case .canceled: "the read of the plugins release was canceled"
        }
    }
}

/// A plugins release, read the way `marfa plugins install` reads it.
///
/// A release is a folder of files at one address: `plugins.json`, which lists the bundles, and each bundle. Reading
/// sends no credential, so a release address carrying a user name or password is refused before any request. A
/// redirect is followed up to five times, but not to an address with a user name or password, and not from `https`
/// to `http`. A bundle is used only when its SHA-256 matches the one the index lists.
public struct PluginRelease: Sendable {
    /// The latest release of the plugins repository, which `MARFA_PLUGINS_URL` replaces for the command line.
    public static let latestAddress = "https://github.com/withmarfa/plugins/releases/latest/download"

    /// The index's file name in a release.
    public static let indexFile = "plugins.json"

    private static let redirects = 5
    private static let bodyLimit = 16 * 1024 * 1024
    private static let bodyBudget = Duration.seconds(60)

    /// The release's address, with no trailing slash.
    public let address: String
    private let connection: Connection

    /// A release at `address`, or the latest release where it is `nil` or blank.
    ///
    /// `timeout` is how long a request waits for the server to send more. Throws ``PluginReleaseError`` for an
    /// address that carries a user name or password, or is not `http` or `https` with a host and no query or
    /// fragment; neither the address nor any part of it is in the error.
    public init(address: String? = nil, timeout: Duration = .seconds(30)) throws(PluginReleaseError) {
        try self.init(address: address, through: nil, timeout: timeout)
    }

    /// `base` stands in for the session a request would otherwise go through, for a test to script it.
    init(address: String?, through base: URLSession?, timeout: Duration) throws(PluginReleaseError) {
        let given = address.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        var text = given.isEmpty ? Self.latestAddress : given
        while text.hasSuffix("/") { text.removeLast() }
        guard let parts = URLComponents(string: text) else { throw .addressUnreadable }
        if parts.user != nil || parts.password != nil { throw .addressCarriesCredentials }
        guard let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = parts.host, !host.isEmpty, parts.query == nil, parts.fragment == nil
        else { throw .addressUnreadable }
        self.address = text
        connection = Connection(base: base, timeout: timeout)
    }

    /// The plugins the release lists, ordered as it lists them.
    ///
    /// Throws ``PluginReleaseError/unreachable(address:reason:)`` when `plugins.json` cannot be read, is not in
    /// index format 1, or lists an entry this build cannot use, such as one whose `bundle` is not
    /// `<name>.plugin.json`.
    public func index() async throws(PluginReleaseError) -> [PluginIndexEntry] {
        let bytes = try await get(Self.indexFile)
        do {
            let index = try JSONDecoder().decode(IndexWire.self, from: bytes)
            guard index.format == 1 else {
                throw unreachable("\(Self.indexFile) is not in index format 1, which this build reads")
            }
            return try index.plugins.map { try entry(from: $0) }
        } catch let error as PluginReleaseError {
            throw error
        } catch {
            throw unreachable("\(Self.indexFile) is not an index this build reads")
        }
    }

    /// The bundle `entry` lists, with its bytes checked against the index's SHA-256 and its contents read.
    ///
    /// Throws ``PluginReleaseError/digestMismatch(file:found:listed:)`` for bytes that differ from the digest,
    /// and ``PluginReleaseError/unreachable(address:reason:)`` for a bundle that holds another plugin than
    /// `entry`'s or is not one this build reads. Nothing is sent to a Marfa server.
    public func bundle(for entry: PluginIndexEntry) async throws(PluginReleaseError) -> ReleasedPlugin {
        let file = entry.bundle
        let bytes = try await get(file)
        let found = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard found == entry.sha256.lowercased() else {
            throw .digestMismatch(file: file, found: found, listed: entry.sha256)
        }
        let contents: PluginBundleContents
        do {
            contents = try Self.contents(of: JSONDecoder().decode(BundleWire.self, from: bytes))
        } catch {
            throw unreachable("\(file) is not a plugin bundle this build reads")
        }
        guard contents.name == entry.name else { throw unreachable("\(file) holds another plugin than \(entry.name)") }
        return ReleasedPlugin(entry: entry, bytes: bytes, contents: contents)
    }

    private func unreachable(_ reason: String) -> PluginReleaseError {
        .unreachable(address: address, reason: reason)
    }

    private func entry(from wire: IndexWire.Entry) throws(PluginReleaseError) -> PluginIndexEntry {
        guard Self.isName(wire.name) else {
            throw unreachable("\(Self.indexFile) lists a plugin with an unusable name")
        }
        guard wire.bundle == "\(wire.name).plugin.json" else {
            throw unreachable("\(Self.indexFile) names no bundle file \(wire.name).plugin.json for \(wire.name)")
        }
        guard wire.sha256.utf8.count == 64, wire.sha256.utf8.allSatisfy(Self.isHexByte) else {
            throw unreachable("\(Self.indexFile) gives no SHA-256 for \(wire.name)")
        }
        guard let marfa = PluginVersion(wire.marfa), let version = PluginVersion(wire.version) else {
            throw unreachable("\(Self.indexFile) gives \(wire.name) a version that is not MAJOR.MINOR.PATCH")
        }
        return PluginIndexEntry(
            name: wire.name, title: wire.title, description: wire.description, mark: wire.mark, maker: wire.maker,
            marfa: marfa, version: version, hasConnector: wire.hasConnector ?? false, bundle: wire.bundle,
            sha256: wire.sha256)
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// Lowercase words and numbers joined by hyphens, starting with a word, at most 64 characters.
    private static func isName(_ name: String) -> Bool {
        name.utf8.count <= 64 && name.utf8.first.map { (0x61...0x7a).contains($0) } == true
            && name.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { word in
                !word.isEmpty && word.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) }
            }
    }

    private static func contents(of wire: BundleWire) throws -> PluginBundleContents {
        guard let marfa = PluginVersion(wire.marfa), let version = PluginVersion(wire.version) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return PluginBundleContents(
            name: wire.name, title: wire.title, description: wire.description, mark: wire.mark, maker: wire.maker,
            marfa: marfa, version: version,
            types: wire.types.map {
                .init(
                    id: $0.id, label: $0.label, description: $0.description, parent: $0.parent,
                    icon: $0.displayHints?.icon, guidance: $0.guidance)
            },
            edgeTypes: wire.edgeTypes.map {
                .init(id: $0.id, label: $0.label, reverseLabel: $0.reverseLabel, description: $0.description)
            },
            connector: wire.connector.map { connector in
                .init(
                    source: connector.source, sourceName: connector.sourceName, sourceMark: connector.sourceMark,
                    kinds: connector.kinds.map { .init(name: $0.name, type: $0.type, direction: $0.direction) },
                    settings: (connector.settings ?? []).map {
                        .init(
                            name: $0.name, label: $0.label, kind: $0.kind, isSecret: $0.secret ?? false,
                            isRequired: $0.required, choices: $0.choices ?? [], defaultValue: $0.default)
                    },
                    edgeTypes: connector.edgeTypes ?? [])
            })
    }

    private func get(_ file: String) async throws(PluginReleaseError) -> Data {
        var at = "\(address)/\(file)"
        let deadline = ContinuousClock.now + Self.bodyBudget
        for _ in 0...Self.redirects {
            guard let parts = URLComponents(string: at), parts.user == nil, parts.password == nil,
                let url = parts.url
            else { throw unreachable("a redirect led to an address carrying a user name or password, or none") }
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            let status: Int
            let location: String?
            let body: Data
            do {
                let (bytes, response) = try await connection.session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw unreachable("\(file) was not answered with http")
                }
                status = response.statusCode
                location = response.value(forHTTPHeaderField: "Location")
                if (300..<400).contains(status) {
                    body = Data()
                } else {
                    body = try await Self.read(bytes, of: response, file: file, deadline: deadline, release: self)
                }
            } catch let error as PluginReleaseError {
                throw error
            } catch is CancellationError {
                throw .canceled
            } catch let error as URLError {
                if error.code == .cancelled { throw .canceled }
                throw unreachable(error.localizedDescription)
            } catch {
                throw unreachable("\(file): \(error.localizedDescription)")
            }
            if [301, 302, 303, 307, 308].contains(status) {
                guard let location, let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw unreachable("answered \(status) for \(file) without an address to go to")
                }
                if url.scheme == "https", next.scheme?.lowercased() == "http" {
                    throw unreachable("a redirect from https to http is refused")
                }
                at = next.absoluteString
                continue
            }
            guard (200..<300).contains(status) else { throw unreachable("answered \(status) for \(file)") }
            return body
        }
        throw unreachable("too many redirects for \(file)")
    }

    private static func read(
        _ bytes: URLSession.AsyncBytes, of response: HTTPURLResponse, file: String, deadline: ContinuousClock.Instant,
        release: PluginRelease
    ) async throws -> Data {
        guard (200..<300).contains(response.statusCode) else { return Data() }
        if response.expectedContentLength > Int64(bodyLimit) {
            throw release.unreachable("\(file) is larger than \(bodyLimit) bytes")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > bodyLimit { throw release.unreachable("\(file) is larger than \(bodyLimit) bytes") }
            if data.count % 65_536 == 0, ContinuousClock.now > deadline {
                throw release.unreachable("\(file) did not arrive in time")
            }
        }
        return data
    }
}

private struct IndexWire: Decodable {
    struct Entry: Decodable {
        let name: String
        let title: String
        let description: String
        let mark: String
        let maker: String
        let marfa: String
        let version: String
        let hasConnector: Bool?
        let bundle: String
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case name, title, description, mark, maker, marfa, version, bundle, sha256
            case hasConnector = "has_connector"
        }
    }

    let format: Int
    let plugins: [Entry]
}

private struct BundleWire: Decodable {
    struct TypeDefinition: Decodable {
        struct Hints: Decodable { let icon: String? }
        let id: String
        let label: String?
        let description: String?
        let parent: String?
        let guidance: String?
        let displayHints: Hints?

        enum CodingKeys: String, CodingKey {
            case id, label, description, parent, guidance
            case displayHints = "display_hints"
        }
    }

    struct EdgeTypeDefinition: Decodable {
        let id: String
        let label: String?
        let reverseLabel: String?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case id, label, description
            case reverseLabel = "reverse_label"
        }
    }

    struct Connector: Decodable {
        struct Kind: Decodable {
            let name: String
            let type: String
            let direction: String
        }

        struct Setting: Decodable {
            let name: String
            let label: String
            let kind: String
            let secret: Bool?
            let required: Bool
            let choices: [String]?
            let `default`: JSONValue?
        }

        let source: String
        let sourceName: String
        let sourceMark: String?
        let kinds: [Kind]
        let settings: [Setting]?
        let edgeTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case source, kinds, settings
            case sourceName = "source_name"
            case sourceMark = "source_mark"
            case edgeTypes = "edge_types"
        }
    }

    let name: String
    let title: String
    let description: String
    let mark: String
    let maker: String
    let marfa: String
    let version: String
    let types: [TypeDefinition]
    let edgeTypes: [EdgeTypeDefinition]
    let connector: Connector?

    enum CodingKeys: String, CodingKey {
        case name, title, description, mark, maker, marfa, version, types, connector
        case edgeTypes = "edge_types"
    }
}
