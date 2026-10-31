import Foundation
internal import MarfaCore

/// The public description of the instance currently answering at a server's address.
public struct InstanceDescription: Sendable, Hashable {
    public let name: String
    public let version: String
    /// Absent when the server's build is not a numbered release.
    public let release: String?
    public let instanceId: String
    public let contract: UInt64
    public let features: [String]

    /// For an app's previews and tests.
    public init(
        name: String, version: String, release: String? = nil, instanceId: String, contract: UInt64,
        features: [String]
    ) {
        self.name = name
        self.version = version
        self.release = release
        self.instanceId = instanceId
        self.contract = contract
        self.features = features
    }

    init(_ core: MarfaCore.InstanceDescription) {
        self.init(
            name: core.name, version: core.version, release: core.release, instanceId: core.instanceId,
            contract: core.contract, features: core.features)
    }
}

extension Server {
    /// Reads the public JSON description without sending the key or reading the keychain.
    ///
    /// Preserves the address's path prefix. An unavailable server, an HTTP refusal, a redirect, or a malformed
    /// description throws a ``MarfaError``. The server supplies the default name `Marfa` when no name is configured.
    /// This read needs no working copy and does not establish data access or contract compatibility.
    public func instanceDescription() async throws -> InstanceDescription {
        let address = url.absoluteString
        return try await background {
            InstanceDescription(try MarfaCore.instanceDescription(url: address))
        }
    }
}
