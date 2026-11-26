import Foundation
import Marfa
import MarfaAPI
import Testing

extension LiveWorkingCopies {
    @Suite(.enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"))
    struct LiveTypeProvenance {
        @Test func aPluginTypeKeepsItsLastInstalledVersionAfterRemoval() async throws {
            let server = try #require(Live.server)
            let copy = try await Live.hydrated()
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let name = "reading-\(suffix)"
            let id = "common.story\(suffix)"
            #expect(try await copy.catalog.itemType("core.note").origin == .platform)
            #expect(try await !copy.catalog.itemTypes().contains { $0.id == id })
            for version in ["1.0.0", "1.0.1"] {
                let bundle = Data(
                    """
                    {"format":1,"name":"\(name)","version":"\(version)","title":"Reading","description":"Stories",
                     "maker":"Tests","mark":"lucide:book","marfa":"0.0.1","edge_types":[],
                     "types":[{"id":"\(id)","description":"A story.","fields":{"title":{"type":"string"}}}]}
                    """.utf8)
                _ = try await server.install(pluginBundle: bundle)
                _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
                let type = try await copy.catalog.itemType(id)
                #expect(type.origin == .plugin)
                #expect(type.plugin == TypePlugin(name: name, version: version))
                #expect(try await copy.catalog.fromServer().itemTypes.first { $0.id == id } == type)
            }
            _ = try await Client(server).removePlugin(path: .init(name: name)).ok
            _ = try await copy.hydrate(types: ["core.note"], tier: .feed)
            let retained = try #require(try await copy.catalog.itemTypes().first { $0.id == id })
            #expect(retained.origin == .plugin)
            #expect(retained.plugin == TypePlugin(name: name, version: "1.0.1"))
            await copy.close()
        }
    }
}
