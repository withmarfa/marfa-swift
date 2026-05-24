import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("MetadataNamespace")
struct MetadataTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleMetadata() -> MetadataResponse {
        MetadataResponse(metadata: Metadata(
            extensions: [:],
            itemId: "item-1",
            tags: ["work", "dev"]
        ))
    }

    @Test("Get metadata sends GET /items/:id/metadata")
    func getMetadata() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleMetadata())

        let meta = try await client.metadata.get(itemId: "item-1")

        #expect(meta.tags == ["work", "dev"])
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/items/item-1/metadata")
    }

    @Test("Add tags sends POST /items/:id/tags")
    func addTags() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(MetadataResponse(metadata: Metadata(
            extensions: [:],
            itemId: "item-1",
            tags: ["work", "dev", "new-tag"]
        )))

        let meta = try await client.metadata.addTags(itemId: "item-1", tags: ["new-tag"])

        #expect(meta.tags.contains("new-tag"))
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/items/item-1/tags")
    }

    @Test("Remove tag sends DELETE /items/:id/tags/:tag")
    func removeTag() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.metadata.removeTag(itemId: "item-1", tag: "work")

        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/items/item-1/tags/work")
    }

    @Test("Set metadata sends PUT /items/:id/metadata")
    func setMetadata() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleMetadata())

        let meta = try await client.metadata.set(
            itemId: "item-1",
            input: MetadataInput(tags: ["work", "dev"])
        )

        #expect(meta.tags == ["work", "dev"])
        #expect(mock.calls[0].method == .put)
    }

    @Test("Missing item_id field on the wire fails decoding")
    func strictDecodingRequiresItemId() throws {
        let body = #"{"tags":[],"extensions":{}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Metadata.self, from: Data(body.utf8))
        }
    }

    @Test("Well-formed wire body decodes every field")
    func strictDecodingHappyPath() throws {
        let body = #"{"item_id":"item-9","tags":["x"],"extensions":{"theme":"dark"}}"#
        let meta = try JSONDecoder().decode(Metadata.self, from: Data(body.utf8))

        #expect(meta.itemId == "item-9")
        #expect(meta.tags == ["x"])
        #expect(meta.extensions["theme"] == .string("dark"))
    }

    // MARK: - listTags (remote)

    @Test("listTags sends GET /metadata/tags with no query in remote mode")
    func listTagsRemote() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(TagListResponsePayload(tags: [
            TagWithCount(tag: "work", count: 3),
            TagWithCount(tag: "dev", count: 2),
        ]))

        let tags = try await client.metadata.listTags()

        #expect(tags.count == 2)
        #expect(tags[0].tag == "work")
        #expect(tags[0].count == 3)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/metadata/tags")
        #expect(mock.calls[0].query == nil)
    }

    @Test("listTags propagates transport errors")
    func listTagsRemoteError() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(URLError(.notConnectedToInternet))

        await #expect(throws: URLError.self) {
            _ = try await client.metadata.listTags()
        }
    }
}

// Test-only mirror of the internal `TagListResponse` envelope. Declared here
// rather than exposing the internal type for tests — the wire shape
// (`{"tags": [{tag, count}]}`) is what matters.
private struct TagListResponsePayload: Codable {
    let tags: [TagWithCount]
}
