import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("ConnectionsNamespace")
struct ConnectionsNamespaceTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
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

    @Test("leaseTokens.create sends POST /connections/{id}/lease-tokens")
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
        #expect(mock.calls[0].path == "/connections/conn-1/lease-tokens")
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

    @Test("previewEvent sends POST /connections/preview-event with input body")
    func previewEvent() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(PreviewEventResult(
            envelopes: [
                PreviewEventEnvelope(
                    connectionId: "conn-1",
                    integrationName: "demo.publisher",
                    wouldDispatch: true,
                    dispatchReason: .ok,
                    envelope: PreviewEventQueueBody(
                        kind: "item-event",
                        integrationName: "demo.publisher",
                        connectionId: "conn-1",
                        tenantId: "tenant-1",
                        eventType: "created",
                        itemId: "item-1",
                        cycle: PreviewEventQueueCycle(
                            originatingConnectionId: nil,
                            hopCount: 0
                        ),
                        payload: .dictionary(["title": .string("hi")])
                    )
                ),
                PreviewEventEnvelope(
                    connectionId: "conn-2",
                    integrationName: "demo.silent",
                    wouldDispatch: false,
                    dispatchReason: .selfEvent,
                    envelope: nil
                )
            ],
            hopBudget: PreviewEventHopBudget(max: 3, used: 0)
        ))

        let result = try await client.connections.previewEvent(
            PreviewEventRequest(itemId: "item-1", eventType: .created)
        )

        #expect(result.envelopes.count == 2)
        #expect(result.envelopes[0].wouldDispatch)
        #expect(result.envelopes[0].dispatchReason == .ok)
        #expect(result.envelopes[0].envelope?.itemId == "item-1")
        #expect(result.envelopes[1].dispatchReason == .selfEvent)
        #expect(result.envelopes[1].envelope == nil)
        #expect(result.hopBudget.max == 3)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/connections/preview-event")
        #expect(mock.calls[0].body != nil)
    }

    @Test("previewEvent encodes event_type and cycle in snake_case")
    func previewEventEncoding() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(PreviewEventResult(
            envelopes: [],
            hopBudget: PreviewEventHopBudget(max: 3, used: 1)
        ))

        _ = try await client.connections.previewEvent(
            PreviewEventRequest(
                itemId: "item-1",
                eventType: .stateChanged,
                connectionId: "conn-target",
                cycle: PreviewEventCycle(
                    originatingConnectionId: "conn-orig",
                    hopCount: 2
                )
            )
        )

        let body = mock.calls[0].body!
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["item_id"] as? String == "item-1")
        #expect(json["event_type"] as? String == "state_changed")
        #expect(json["connection_id"] as? String == "conn-target")
        let cycle = json["cycle"] as! [String: Any]
        #expect(cycle["originating_connection_id"] as? String == "conn-orig")
        #expect(cycle["hop_count"] as? Int == 2)
    }

    @Test("Pure-local rejects install + lifecycle operations + previewEvent")
    func localModeRejects() async throws {
        let client = try await MarfaClient.local(path: ":memory:")

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
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.connections.previewEvent(
                PreviewEventRequest(itemId: "item-1", eventType: .created)
            )
        }
    }
}
