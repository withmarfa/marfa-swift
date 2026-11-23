import Foundation
import MarfaAPI
import Testing

@testable import Marfa

/// An app's own data against a server of the test's own: an app signs in and writes under its `app.<vendor>`
/// namespace, and the owner lists that data, deletes it over more than one page, and removes it at disconnect.
@Suite(
    .serialized,
    .enabled(if: OwnServer.monorepo != nil, "set MARFA_MONOREPO to a marfa checkout whose server is built"))
struct LiveAppData {
    static let service = "com.withmarfa.marfa-swift.tests"
    static let appName = "marfa-swift app data live tests"

    @Test(.timeLimit(.minutes(10))) func theOwnerListsAndDeletesAnAppsDataAndRemovesItAtDisconnect() async throws {
        let own = try await OwnServer.boot()
        do {
            try await inIsolatedKeychainAsync { keychain, _ async throws in
                try await Self.listDeleteAndDisconnect(own, keychain)
            }
        } catch {
            try await own.end()
            throw error
        }
        try await own.end()
    }

    private static func listDeleteAndDisconnect(_ own: OwnServer, _ keychain: Keychain) async throws {
        let authorization = try Authorization(
            server: own.url,
            client: Authorization.Client(
                name: appName, redirect: URL(string: "com.withmarfa.marfa-swift.tests:/signed-in"),
                scopes: ["content:write", "metadata.types:write"]),
            keychain: keychain, service: service)
        let credential = try await authorization.signIn(browser: LiveSignIn.browserApproval(on: own))
        let app = try Server(url: own.url, credential: credential)
        let vendor = "app.swift\(UUID().uuidString.prefix(8).lowercased())"
        let type = "\(vendor).note"
        let title = Components.Schemas.FieldDefinition(_type: .string)
        let fields = Components.Schemas.TypeDefinitionInput.FieldsPayload(additionalProperties: ["title": title])
        _ = try await Client(app).register(itemType: .init(fields: fields, id: type))
        try await bulkCreate(1_050, of: type, on: app)

        let owner = Client(own.server)
        let grant = try #require(
            try await owner.listAppGrants().ok.body.json.data.first { $0.clientName == appName })
        #expect(grant.vendors == [vendor])
        let held = try await owner.listAppVendors().ok.body.json.data.first { $0.vendor == vendor }
        #expect(held?.clientName == appName)

        var listed = 0
        var pages = 0
        var cursor: String?
        repeat {
            let page = try await owner.appData(vendor: vendor, limit: 200, cursor: cursor)
            #expect(page.types.map(\._type) == [type])
            #expect(page.types.first?.active == 1_050)
            listed += page.data.count
            pages += 1
            cursor = page.nextCursor
        } while cursor != nil && pages < 10
        #expect(listed == 1_050)
        #expect(pages == 6)

        let removal = try await owner.removeAppData(vendor: vendor, .ownerConfirmed)
        #expect(removal.isComplete)
        #expect(removal.removedItems == 1_050)
        #expect(removal.removedTypes == 1)
        let emptied = try await owner.appData(vendor: vendor)
        #expect(emptied.types.isEmpty && emptied.data.isEmpty)
        let again = try await owner.removeAppData(vendor: vendor, .ownerConfirmed)
        #expect(again.isComplete && again.removedItems == 0)

        // The vendor stays with the app, so it registers its type again and writes a little more.
        _ = try await Client(app).register(itemType: .init(fields: fields, id: type))
        try await bulkCreate(3, of: type, on: app)
        try await owner.disconnect(grant: grant.id)
        let kept = try await owner.appData(vendor: vendor)
        #expect(kept.types.first?.active == 3)

        // Kept data alone is no grant to remove, so a second app signs in to be removed with its data.
        try await removedWithItsData(own, keychain, owner)
    }

    private static func removedWithItsData(_ own: OwnServer, _ keychain: Keychain, _ owner: Client) async throws {
        let authorization = try Authorization(
            server: own.url,
            client: Authorization.Client(
                name: "\(appName) 2", redirect: URL(string: "com.withmarfa.marfa-swift.tests:/signed-in"),
                scopes: ["content:write", "metadata.types:write"]),
            keychain: keychain, service: "\(service).second")
        let app = try Server(
            url: own.url, credential: try await authorization.signIn(browser: LiveSignIn.browserApproval(on: own)))
        let vendor = "app.swift\(UUID().uuidString.prefix(8).lowercased())"
        let type = "\(vendor).note"
        let title = Components.Schemas.FieldDefinition(_type: .string)
        let fields = Components.Schemas.TypeDefinitionInput.FieldsPayload(additionalProperties: ["title": title])
        _ = try await Client(app).register(itemType: .init(fields: fields, id: type))
        try await bulkCreate(2, of: type, on: app)
        let signIn = try #require(
            try await owner.listSignIns().ok.body.json.data.first { $0.kind == .app && $0.name == "\(appName) 2" })
        try await owner.end(signIn: signIn.id, data: .remove(.ownerConfirmed))
        let left = try await owner.appData(vendor: vendor)
        #expect(left.types.isEmpty && left.data.isEmpty)
    }

    private static func bulkCreate(_ count: Int, of type: String, on server: Server) async throws {
        let run = UUID().uuidString.prefix(8)
        var start = 0
        while start < count {
            let end = min(start + 500, count)
            var request = URLRequest(url: server.url.appending(path: "items/bulk"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(try server.currentToken())", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let items = (start..<end).map { index -> [String: Any] in
                ["type": type, "source_id": "\(run)-\(index)", "properties": ["title": "note \(index)"]]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": "create_only", "items": items])
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try #require((response as? HTTPURLResponse)?.statusCode)
            #expect(status == 200, "\(String(decoding: data, as: UTF8.self))")
            start = end
        }
    }
}
