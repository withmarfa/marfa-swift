import CryptoKit
import Foundation
import MarfaAPI
import Testing

@testable import Marfa

/// Installing a plugin's bytes against a server of the test's own: the fingerprint the server records is the
/// bundle's SHA-256, a plugin that needs a later Marfa is told apart, and an app's install of guidance is refused.
@Suite(
    .serialized,
    .enabled(if: OwnServer.monorepo != nil, "set MARFA_MONOREPO to a marfa checkout whose server is built"),
    .timeLimit(.minutes(5)))
struct LivePluginInstall {
    static let service = "com.withmarfa.marfa-swift.tests"

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A bundle in spacing a decoder would not write, so a re-encoded copy has another digest.
    private static func bundle(
        name: String, type: String, marfa: String = "0.0.1", guidance: String? = nil, version: String = "1.0.0"
    ) -> Data {
        let guide = guidance.map { ", \"guidance\": \"\($0)\"" } ?? ""
        return Data(
            """
            {  "name": "\(name)",   "format": 1,
               "title": "Live",  "description": "A plugin the live test installs.", "mark": "lucide:box",
               "maker": "Tests", "marfa": "\(marfa)",\t"version": "\(version)", "edge_types": [ ],
               "types": [ { "id": "\(type)", "description": "A thing.", "fields": { "title": { "type": "string" } }\(guide) } ]
            }

            """.utf8)
    }

    @Test func theServerRecordsTheDigestOfTheBytesSentAndToldRefusalsAreRead() async throws {
        let own = try await OwnServer.boot()
        do {
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                try await Self.run(own, keychain)
            }
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    private static func run(_ own: OwnServer, _ keychain: Keychain) async throws {
        let part = UUID().uuidString.prefix(8).lowercased()
        let owner = own.server

        let name = "live-\(part)"
        let bytes = bundle(name: name, type: "common.live\(part)", guidance: "Use it for live things.")
        let installed = try await owner.install(pluginBundle: bytes)
        #expect(installed.outcome == .installed)
        #expect(installed.fingerprint == digest(bytes))
        let read = try await Client(owner).getPlugin(path: .init(name: name)).ok.body.json
        #expect(read.fingerprint == digest(bytes))
        let again = try await owner.install(pluginBundle: bytes)
        #expect(again.outcome == .unchanged && again.fingerprint == digest(bytes))

        // The witness: the generated call decodes and encodes the bundle again, which changes its digest.
        let other = "live-\(part)-b"
        let spaced = bundle(name: other, type: "common.liveb\(part)")
        let decoded = try JSONDecoder().decode(Components.Schemas.PluginBundle.self, from: spaced)
        let regenerated = try await Client(owner).installPlugin(body: .json(decoded)).created.body.json
        #expect(regenerated.fingerprint != digest(spaced))

        let tooNew = bundle(name: "live-\(part)-new", type: "common.livenew\(part)", marfa: "99.0.0")
        do {
            _ = try await owner.install(pluginBundle: tooNew)
            Issue.record("a plugin that needs Marfa 99.0.0 was installed")
        } catch {
            guard case .needsNewerServer(let marfa, let server)? = error.pluginInstallRefusal else {
                Issue.record("\(error)")
                return
            }
            #expect(marfa == "99.0.0" && PluginVersion(server) != nil)
        }

        try await appRefusedGuidance(own, keychain, part: String(part))
    }

    private static func appRefusedGuidance(_ own: OwnServer, _ keychain: Keychain, part: String) async throws {
        let root = "guided\(part)"
        let title = Components.Schemas.FieldDefinition(_type: .string)
        let fields = Components.Schemas.TypeDefinitionInput.FieldsPayload(additionalProperties: ["title": title])
        _ = try await Client(own.server).register(itemType: .init(fields: fields, id: "\(root).anchor"))
        let authorization = try Authorization(
            server: own.url,
            client: Authorization.Client(
                name: "plugin install live tests", redirect: URL(string: "com.withmarfa.marfa-swift.tests:/signed-in"),
                scopes: ["\(root).*:write", "schema.write"]),
            keychain: keychain, service: service)
        let credential = try await authorization.signIn(browser: LiveSignIn.browserApproval(on: own))
        let app = try Server(url: own.url, credential: credential)

        let name = "guided-\(part)"
        let guided = bundle(name: name, type: "\(root).thing", guidance: "Installing writes this.")
        do {
            _ = try await app.install(pluginBundle: guided)
            Issue.record("an app installed guidance")
        } catch {
            #expect(error.pluginInstallRefusal == .carriesGuidance, "\(error)")
        }
        let plain = bundle(name: name, type: "\(root).thing")
        let installed = try await app.install(pluginBundle: plain)
        #expect(installed.outcome == .installed && installed.fingerprint == digest(plain))
    }
}
