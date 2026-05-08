import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("IntegrationsNamespace")
struct IntegrationsNamespaceTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleIntegration() -> Integration {
        Integration(
            direction: .read,
            id: "int-1",
            manifest: ["name": .string("acme.calendar-sync")],
            manifestName: "acme.calendar-sync",
            manifestVersion: "1.0.0",
            publisher: "Acme Inc.",
            registeredAt: "2026-05-01T00:00:00Z",
            runtimeCompatibility: ["hosted"],
            summary: "Calendar sync"
        )
    }

    @Test("list sends GET /integrations and unwraps the data envelope")
    func listIntegrations() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable {
            let data: [Integration]
        }
        mock.enqueue(Envelope(data: [sampleIntegration()]))

        let result = try await client.integrations.list()

        #expect(result.count == 1)
        #expect(result[0].manifestName == "acme.calendar-sync")
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/integrations")
    }

    @Test("list passes manifest_name and limit as query params")
    func listWithFilters() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable {
            let data: [Integration]
        }
        mock.enqueue(Envelope(data: []))

        _ = try await client.integrations.list(manifestName: "acme.x", limit: 50)

        let query = mock.calls[0].query ?? []
        #expect(query.contains(where: { $0.0 == "manifest_name" && $0.1 == "acme.x" }))
        #expect(query.contains(where: { $0.0 == "limit" && $0.1 == "50" }))
    }

    @Test("get sends GET /integrations/{id}")
    func getIntegration() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleIntegration())

        let result = try await client.integrations.get("int-1")

        #expect(result.id == "int-1")
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/integrations/int-1")
    }

    @Test("register sends POST /integrations with manifest body")
    func registerIntegration() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleIntegration())

        let manifest: [String: JSONValue] = [
            "name": .string("acme.calendar-sync"),
            "version": .string("1.0.0")
        ]
        let result = try await client.integrations.register(manifest: manifest)

        #expect(result.id == "int-1")
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/integrations")
        #expect(mock.calls[0].body != nil)
    }

    @Test("Pure-local mode rejects every integration call")
    func localModeRejects() async throws {
        let client = try await MymeClient.local(path: ":memory:")

        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.integrations.list()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.integrations.get("int-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.integrations.register(manifest: [:])
        }
    }
}
