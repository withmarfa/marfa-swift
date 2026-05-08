import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("ConnectionsNamespace")
struct ConnectionsNamespaceTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    @Test("install sends POST /connections/install with input body")
    func install() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(ConnectionInstallResult(
            activityId: "act-1",
            connectionId: "conn-1",
            credentialId: "cred-1"
        ))

        let result = try await client.connections.install(
            integrationId: "int-1",
            label: "My Label"
        )

        #expect(result.connectionId == "conn-1")
        #expect(result.credentialId == "cred-1")
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/connections/install")
        #expect(mock.calls[0].body != nil)
    }

    @Test("uninstall sends POST /connections/{id}/uninstall")
    func uninstall() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(ConnectionUninstallResult(
            activityId: "act-2",
            connectionId: "conn-1",
            inboundWebhooksDisabled: 0,
            leasedTokensRevoked: 1,
            oauthTokensDeleted: true,
            revokedCredentialIds: ["cred-1"]
        ))

        let result = try await client.connections.uninstall("conn-1")

        #expect(result.leasedTokensRevoked == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/connections/conn-1/uninstall")
    }

    @Test("leaseTokens.create sends POST /connections/{id}/lease-token")
    func leaseTokenCreate() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(CreatedLeaseToken(
            capabilityId: "cap-1",
            connectionId: "conn-1",
            createdAt: "2026-05-01T00:00:00Z",
            expiresAt: "2026-05-01T01:00:00Z",
            id: "lease-1",
            leaseToken: "secret-token-value",
            revokedAt: nil,
            scopes: ["read"],
            tenantId: "tenant-1"
        ))

        let result = try await client.connections.leaseTokens.create(
            connectionId: "conn-1",
            capabilityId: "cap-1",
            scopes: ["read"],
            ttlSeconds: 3600
        )

        #expect(result.leaseToken == "secret-token-value")
        #expect(mock.calls[0].path == "/connections/conn-1/lease-token")
    }

    @Test("leaseTokens.list returns array under leases envelope")
    func leaseTokenList() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable {
            let leases: [LeaseToken]
        }
        mock.enqueue(Envelope(leases: [
            LeaseToken(
                capabilityId: "cap-1",
                connectionId: "conn-1",
                createdAt: "2026-05-01T00:00:00Z",
                expiresAt: "2026-05-01T01:00:00Z",
                id: "lease-1",
                revokedAt: nil,
                scopes: ["read"],
                tenantId: "tenant-1"
            )
        ]))

        let result = try await client.connections.leaseTokens.list(connectionId: "conn-1")

        #expect(result.count == 1)
        #expect(result[0].id == "lease-1")
        #expect(mock.calls[0].path == "/connections/conn-1/lease-tokens")
    }

    @Test("inboundWebhooks.retryDelivery sends POST to retry path")
    func retryDelivery() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.connections.inboundWebhooks.retryDelivery(
            connectionId: "conn-1",
            webhookId: "wh-1",
            eventId: "evt-1"
        )

        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/connections/conn-1/inbound-webhooks/wh-1/deliveries/evt-1/retry")
    }

    @Test("Pure-local rejects install + lifecycle operations")
    func localModeRejects() async throws {
        let client = try await MymeClient.local(path: ":memory:")

        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.connections.install(integrationId: "int-1", label: nil)
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.connections.uninstall("conn-1")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.connections.leaseTokens.create(
                connectionId: "conn-1",
                capabilityId: "cap-1",
                scopes: nil,
                ttlSeconds: nil
            )
        }
    }
}
