import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

@Suite("ItemsNamespace — bulk + bulkAction")
struct BulkTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleBulkResult() -> BulkResult {
        BulkResult(
            counts: BulkResultCounts(created: 1, updated: 0, skipped: 0, errored: 0),
            results: [
                BulkResultEntry(
                    index: 0, outcome: .created, id: "itm_abc", reason: nil, error: nil
                )
            ],
            blobsImported: nil
        )
    }

    func sampleBulkActionResult(action: String) -> BulkActionResult {
        BulkActionResult(
            action: action,
            matched: 3,
            succeeded: 3,
            errored: 0,
            dryRun: false,
            ids: nil,
            errors: nil,
            blobHashesReferenced: action == "purge" ? 0 : nil
        )
    }

    // MARK: - bulk

    @Test("bulk sends POST /items/bulk with BulkInput body")
    func bulkPostsExpectedBody() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleBulkResult())

        let input = BulkInput(
            items: [
                BulkItemInput(
                    type: "core.note",
                    properties: ["title": .string("one")],
                    sourceId: "s1"
                )
            ],
            mode: .upsert,
            atomic: true
        )
        let result = try await client.items.bulk(input)

        #expect(result.counts.created == 1)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/items/bulk")
    }

    @Test("bulk encodes mode as snake_case value (create_only)")
    func bulkModeCreateOnlyEncodesAsSnakeCase() throws {
        let input = BulkInput(
            items: [BulkItemInput(type: "core.note")],
            mode: .createOnly
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"mode\":\"create_only\""))
    }

    @Test("bulk snake-cases field names on the wire")
    func bulkEncodesSnakeCaseFields() throws {
        let input = BulkInput(
            items: [
                BulkItemInput(type: "core.note", sourceId: "abc")
            ],
            emitEvents: true
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"source_id\":\"abc\""))
        #expect(json.contains("\"emit_events\":true"))
    }

    // MARK: - bulkAction

    @Test("bulkAction transition posts to /items/bulk_action")
    func bulkActionTransitionPath() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleBulkActionResult(action: "transition"))

        let input = BulkActionInput.transition(
            filter: BulkActionFilter(tags: ["x"]),
            state: .archived
        )
        let result = try await client.items.bulkAction(input)

        #expect(result.action == "transition")
        #expect(result.succeeded == 3)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].path == "/items/bulk_action")
        #expect(mock.calls[0].method == .post)
    }

    @Test("bulkAction encodes discriminator + params for each verb")
    func bulkActionDiscriminatorEncoding() throws {
        let encoder = JSONEncoder()

        let transition = try encoder.encode(BulkActionInput.transition(
            filter: BulkActionFilter(tags: ["t"]), state: .trashed
        ))
        #expect(String(data: transition, encoding: .utf8)!.contains("\"action\":\"transition\""))
        #expect(String(data: transition, encoding: .utf8)!.contains("\"state\":\"trashed\""))

        let updateLibrary = try encoder.encode(BulkActionInput.updateLibrary(
            filter: BulkActionFilter(type: "core.note"), library: false
        ))
        let libJson = String(data: updateLibrary, encoding: .utf8)!
        #expect(libJson.contains("\"action\":\"update_library\""))
        #expect(libJson.contains("\"library\":false"))

        let updateTimestamp = try encoder.encode(BulkActionInput.updateTimestamp(
            filter: BulkActionFilter(), timestamp: "2020-01-01T00:00:00Z"
        ))
        let tsJson = String(data: updateTimestamp, encoding: .utf8)!
        #expect(tsJson.contains("\"action\":\"update_timestamp\""))
        #expect(tsJson.contains("\"timestamp\":\"2020-01-01T00:00:00Z\""))

        let updateTags = try encoder.encode(BulkActionInput.updateTags(
            filter: BulkActionFilter(), add: ["a"], remove: ["b"]
        ))
        let tagsJson = String(data: updateTags, encoding: .utf8)!
        #expect(tagsJson.contains("\"action\":\"update_tags\""))
        #expect(tagsJson.contains("\"add\":[\"a\"]"))
        #expect(tagsJson.contains("\"remove\":[\"b\"]"))

        let updateProperties = try encoder.encode(BulkActionInput.updateProperties(
            filter: BulkActionFilter(), patch: ["k": .string("v")]
        ))
        let propJson = String(data: updateProperties, encoding: .utf8)!
        #expect(propJson.contains("\"action\":\"update_properties\""))
        #expect(propJson.contains("\"patch\":{\"k\":\"v\"}"))
    }

    @Test("bulkAction purge refuses to encode without confirm = PURGE")
    func bulkActionPurgeGuardsConfirm() {
        let input = BulkActionInput.purge(
            filter: BulkActionFilter(type: "core.note"),
            options: BulkActionOptions()
        )
        #expect(throws: (any Error).self) {
            _ = try JSONEncoder().encode(input)
        }
    }

    @Test("bulkAction purge encodes confirm literal when supplied")
    func bulkActionPurgeWithConfirm() throws {
        let input = BulkActionInput.purge(
            filter: BulkActionFilter(type: "core.note"),
            options: BulkActionOptions(confirm: "PURGE")
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"action\":\"purge\""))
        #expect(json.contains("\"confirm\":\"PURGE\""))
    }

    @Test("bulkAction encodes dry_run + max_items as snake_case")
    func bulkActionOptionsEncoding() throws {
        let input = BulkActionInput.transition(
            filter: BulkActionFilter(),
            state: .archived,
            options: BulkActionOptions(dryRun: true, maxItems: 100, emitEvents: true)
        )
        let data = try JSONEncoder().encode(input)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"dry_run\":true"))
        #expect(json.contains("\"max_items\":100"))
        #expect(json.contains("\"emit_events\":true"))
    }

    @Test("bulkAction round-trips through JSON (replay-queue shape)")
    func bulkActionRoundTrip() throws {
        // SyncEngine replay decodes the payload from the mutation queue;
        // this proves the BulkActionInput Decodable impl agrees with the
        // Encodable impl. Assert the `action` discriminator survives
        // the round-trip for every case — encoded byte equality is too
        // strict because JSONEncoder key ordering isn't stable across
        // calls.
        let cases: [(BulkActionInput, String)] = [
            (.transition(filter: BulkActionFilter(type: "core.note"), state: .archived), "transition"),
            (.purge(filter: BulkActionFilter(tags: ["dead"]), options: BulkActionOptions(confirm: "PURGE")), "purge"),
            (.updateTags(filter: BulkActionFilter(), add: ["x"], remove: nil), "update_tags"),
            (.updateLibrary(filter: BulkActionFilter(), library: true), "update_library"),
            (.updateProperties(filter: BulkActionFilter(), patch: ["k": .int(42)]), "update_properties"),
            (.updateTimestamp(filter: BulkActionFilter(), timestamp: "2024-01-01T00:00:00Z"), "update_timestamp"),
        ]
        for (input, expectedAction) in cases {
            let data = try JSONEncoder().encode(input)
            let decoded = try JSONDecoder().decode(BulkActionInput.self, from: data)
            // Destructure via encode path — re-encode must still contain
            // the same discriminator.
            let reencoded = try JSONEncoder().encode(decoded)
            let reJson = String(data: reencoded, encoding: .utf8)!
            #expect(reJson.contains("\"action\":\"\(expectedAction)\""))
        }
    }

    @Test("Bulk server errors surface as typed errors")
    func bulkAtomicRollbackErrorSurfaces() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(ValidationError(message: "bulk_atomic_rollback"))

        await #expect(throws: ValidationError.self) {
            _ = try await client.items.bulk(
                BulkInput(items: [BulkItemInput(type: "core.note")])
            )
        }
    }
}
