import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("EdgesNamespace — bulk")
struct BulkEdgesTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleEdgeResult() -> BulkEdgeResult {
        BulkEdgeResult(
            counts: BulkResultCounts(
                created: 1, updated: 0, skipped: 0, errored: 0
            ),
            results: [
                BulkEdgeResultEntry(
                    index: 0, outcome: .created, id: "edg_abc"
                )
            ]
        )
    }

    @Test("bulk sends POST /edges/bulk with BulkEdgeInput body")
    func bulkPostsExpectedBody() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleEdgeResult())

        let input = BulkEdgeInput(
            edges: [
                BulkEdgeInputItem(
                    sourceId: "src1",
                    targetId: "tgt1",
                    edgeType: "about"
                )
            ],
            mode: .upsert,
            atomic: true
        )
        let result = try await client.edges.bulk(input)

        #expect(result.counts.created == 1)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/edges/bulk")
    }

    @Test("bulk encodes snake_case field names on the wire")
    func bulkEncodesSnakeCaseFields() throws {
        let input = BulkEdgeInput(
            edges: [
                BulkEdgeInputItem(
                    sourceId: "s",
                    targetId: "t",
                    edgeType: "about",
                    properties: ["weight": .int(1)]
                )
            ],
            emitEvents: true
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"source_id\":\"s\""))
        #expect(json.contains("\"target_id\":\"t\""))
        #expect(json.contains("\"edge_type\":\"about\""))
        #expect(json.contains("\"emit_events\":true"))
    }

    @Test("bulk encodes mode as create_only snake_case value")
    func bulkModeCreateOnly() throws {
        let input = BulkEdgeInput(
            edges: [
                BulkEdgeInputItem(
                    sourceId: "s", targetId: "t", edgeType: "about"
                )
            ],
            mode: .createOnly
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"mode\":\"create_only\""))
    }

    @Test("bulk decodes the full result shape")
    func bulkDecodesResult() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(BulkEdgeResult(
            counts: BulkResultCounts(
                created: 1, updated: 1, skipped: 1, errored: 1
            ),
            results: [
                BulkEdgeResultEntry(index: 0, outcome: .created, id: "e1"),
                BulkEdgeResultEntry(index: 1, outcome: .updated, id: "e2"),
                BulkEdgeResultEntry(
                    index: 2, outcome: .skipped, id: "e3",
                    reason: "duplicate_edge"
                ),
                BulkEdgeResultEntry(
                    index: 3, outcome: .errored,
                    error: BulkResultError(
                        code: "invalid_id",
                        message: "Invalid source_id: bad"
                    )
                ),
            ]
        ))

        let result = try await client.edges.bulk(BulkEdgeInput(edges: [
            BulkEdgeInputItem(sourceId: "a", targetId: "b", edgeType: "about"),
        ]))

        #expect(result.counts.created == 1)
        #expect(result.counts.updated == 1)
        #expect(result.counts.skipped == 1)
        #expect(result.counts.errored == 1)
        #expect(result.results[2].reason == "duplicate_edge")
        #expect(result.results[3].error?.code == "invalid_id")
    }

    @Test("bulk surfaces server errors as typed errors")
    func bulkErrorSurfaces() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(ValidationError(message: "bulk_atomic_rollback"))

        await #expect(throws: ValidationError.self) {
            _ = try await client.edges.bulk(
                BulkEdgeInput(edges: [
                    BulkEdgeInputItem(
                        sourceId: "s", targetId: "t", edgeType: "about"
                    )
                ])
            )
        }
    }
}
