import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("MetadataNamespace")
struct MetadataTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleMetadata() -> MetadataResponse {
        MetadataResponse(metadata: Metadata(
            about: [],
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
            about: [],
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
        let body = #"{"tags":[],"about":[],"extensions":{}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Metadata.self, from: Data(body.utf8))
        }
    }

    @Test("Well-formed wire body decodes every field")
    func strictDecodingHappyPath() throws {
        let body = #"{"item_id":"item-9","tags":["x"],"about":["entity-1"],"extensions":{}}"#
        let meta = try JSONDecoder().decode(Metadata.self, from: Data(body.utf8))

        #expect(meta.itemId == "item-9")
        #expect(meta.tags == ["x"])
        #expect(meta.about == ["entity-1"])
    }
}
