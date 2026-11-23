import Foundation
import Marfa
import MarfaTypes

/// Why the server refused to install a plugin, for the refusals an app tells the owner about in its own words.
public enum PluginInstallRefusal: Sendable, Hashable {
    /// The plugin needs a later Marfa release than the server runs: `marfa` is the oldest release the plugin works
    /// with, and `server` the release the server runs.
    case needsNewerServer(marfa: String, server: String)
    /// The install would add, change or remove a type's guidance, and the caller is a key an app made, which never
    /// writes guidance. An app's own sign-in writes it once the owner signed in within the last fifteen minutes.
    case carriesGuidance
}

extension MarfaError {
    /// What an install of a plugin was refused for, or `nil` for every other error.
    ///
    /// Read it from what ``Server/install(pluginBundle:expecting:timeout:)`` or the generated `installPlugin`
    /// throws.
    public var pluginInstallRefusal: PluginInstallRefusal? {
        switch self {
        case .server(409, "plugin_needs_newer_server", _, let details, _):
            guard let marfa = details?.object?["marfa"]?.string, let server = details?.object?["server"]?.string
            else { return nil }
            return .needsNewerServer(marfa: marfa, server: server)
        case .forbidden("forbidden", _, let answer):
            let changes = answer?.details?.object?["changes"]?.array ?? []
            return changes.contains { $0.string == "guidance" } ? .carriesGuidance : nil
        default:
            return nil
        }
    }
}

extension Server {
    /// Installs the plugin whose bundle is `bundle`, sending its bytes exactly as given, and answers what the server
    /// recorded.
    ///
    /// The server records the SHA-256 of the bytes it receives as the plugin's `fingerprint`, so installing the bytes
    /// a plugins release lists (``PluginRelease/bundle(for:)``) records the digest the release lists. The generated
    /// `installPlugin` decodes and encodes its bundle again, which changes the bytes and so the fingerprint.
    ///
    /// Needs `schema.write`, write on each type and edge type of the bundle, and `connectors.manage` for a bundle
    /// with a connector. ``MarfaError/pluginInstallRefusal`` tells the refusals that name a plugin apart from the
    /// rest, and the server's other refusals throw as ``MarfaError`` as they do for every call. `instanceID` makes the
    /// server refuse with ``MarfaError/instanceChanged(message:server:)`` when another instance now answers at this
    /// address.
    @discardableResult
    public func install(
        pluginBundle bundle: Data, expecting instanceID: String? = nil, timeout: Duration = Server.defaultTimeout
    ) async throws(MarfaError) -> Components.Schemas.PluginInstalled {
        let headers = instanceID.map { ["X-Marfa-Instance-Id": $0] } ?? [:]
        let data = try await send("POST", "/plugins", headers: headers, body: bundle, timeout: timeout)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try ServerDates().decode(try decoder.singleValueContainer().decode(String.self))
        }
        do {
            return try decoder.decode(Components.Schemas.PluginInstalled.self, from: data)
        } catch {
            throw .decoding(message: "\(origin) answered the install of a plugin in a form this build cannot read")
        }
    }
}
