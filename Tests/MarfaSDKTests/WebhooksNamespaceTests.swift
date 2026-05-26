import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("WebhooksNamespace")
struct WebhooksNamespaceTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func makeWebhook(id: String = "wh-1", url: String = "https://example.test/hook") -> Webhook {
        Webhook(
            active: true,
            createdAt: "2026-05-01T00:00:00Z",
            events: ["item.created"],
            id: id,
            secret: "secret-abc",
            typeFilter: "core.note",
            updatedAt: "2026-05-01T00:00:00Z",
            url: url
        )
    }

    @Test("create POSTs /webhooks with the input body")
    func create() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeWebhook())

        let webhook = try await client.webhooks.create(
            CreateWebhookInput(
                url: "https://example.test/hook",
                events: ["item.created"],
                typeFilter: "core.note",
                secret: "secret-abc"
            )
        )

        #expect(webhook.id == "wh-1")
        #expect(webhook.url == "https://example.test/hook")
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/webhooks")
    }

    @Test("list unwraps the webhooks envelope")
    func list() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable { let webhooks: [Webhook] }
        mock.enqueue(Envelope(webhooks: [makeWebhook(id: "wh-1"), makeWebhook(id: "wh-2")]))

        let webhooks = try await client.webhooks.list()

        #expect(webhooks.count == 2)
        #expect(webhooks[0].id == "wh-1")
        #expect(mock.calls[0].path == "/webhooks")
    }

    @Test("get sends GET /webhooks/{id} and returns the Webhook directly")
    func get() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeWebhook())

        let webhook = try await client.webhooks.get(id: "wh-1")

        #expect(webhook.id == "wh-1")
        #expect(mock.calls[0].path == "/webhooks/wh-1")
    }

    @Test("update sends PATCH /webhooks/{id} with the update body")
    func update() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(makeWebhook())

        _ = try await client.webhooks.update(
            id: "wh-1",
            input: UpdateWebhookInput(active: false)
        )

        #expect(mock.calls[0].method == .patch)
        #expect(mock.calls[0].path == "/webhooks/wh-1")
        let body = mock.calls[0].body!
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["active"] as? Bool == false)
    }

    @Test("delete sends DELETE /webhooks/{id}")
    func delete() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.webhooks.delete(id: "wh-1")

        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/webhooks/wh-1")
    }

    @Test("deliveries unwraps the deliveries envelope and forwards the limit query")
    func deliveries() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable { let deliveries: [WebhookDelivery] }
        let delivery = WebhookDelivery(
            attempt: 1,
            createdAt: "2026-05-01T00:00:00Z",
            error: nil,
            event: "item.created",
            id: "del-1",
            statusCode: 200,
            succeeded: true,
            webhookId: "wh-1"
        )
        mock.enqueue(Envelope(deliveries: [delivery]))

        let deliveries = try await client.webhooks.deliveries(id: "wh-1", limit: 25)

        #expect(deliveries.count == 1)
        #expect(deliveries[0].id == "del-1")
        #expect(mock.calls[0].path == "/webhooks/wh-1/deliveries")
        let query = mock.calls[0].query ?? []
        #expect(query.contains { $0.0 == "limit" && $0.1 == "25" })
    }

    @Test("deliveries omits the limit query when not provided")
    func deliveriesWithoutLimit() async throws {
        let (client, mock) = makeClient()
        struct Envelope: Encodable { let deliveries: [WebhookDelivery] }
        mock.enqueue(Envelope(deliveries: []))

        _ = try await client.webhooks.deliveries(id: "wh-1")

        #expect(mock.calls[0].query == nil || mock.calls[0].query?.isEmpty == true)
    }
}
