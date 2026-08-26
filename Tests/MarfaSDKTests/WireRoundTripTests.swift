import Testing
import Foundation
@testable import MarfaSDK

@Suite("Wire round-trip")
struct WireRoundTripTests {

    /// Decode a fixture into `T`, re-encode, and assert the round-tripped JSON
    /// matches the original structurally (keys, values, nested dictionaries) —
    /// ignoring key order.
    ///
    /// Catches codec bugs the freshness diff can't see: wrong CodingKeys,
    /// missed nullable flags, snake-case mismatches, integer/double confusion.
    private func assertRoundTrip<T: Codable>(
        _: T.Type,
        fixture: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        guard let url = Bundle.module.url(
            forResource: fixture, withExtension: "json", subdirectory: "Fixtures/Wire"
        ) else {
            Issue.record("fixture missing: Fixtures/Wire/\(fixture).json", sourceLocation: sourceLocation)
            return
        }
        let original = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(T.self, from: original)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = try encoder.encode(decoded)
        let lhs = try JSONSerialization.jsonObject(with: original) as! NSDictionary
        let rhs = try JSONSerialization.jsonObject(with: reencoded) as! NSDictionary
        #expect(lhs == rhs, "round-trip mismatch for \(fixture)", sourceLocation: sourceLocation)
    }

    // The hand-written models in this suite are marked as such. The rest are
    // codegen output, regenerated and diffed by the freshness job, so a codec
    // bug in one of them is a bug in the emitter. The hand-written ones have
    // no such backstop, which makes this suite the only place their drift
    // shows up. For a long time it held two of them while the generated
    // types, the category already guarded, made up the rest. The cover sat on
    // the models least likely to drift.
    //
    // Exact equality is the point: a key the model drops on re-encode fails
    // here. What it cannot see is a key the fixture never carried, which is
    // what `WireFixtureSpecDriftTests` is for.
    @Test("SpaceConfig (hand-written)") func spaceConfig() throws {
        try assertRoundTrip(SpaceConfig.self, fixture: "space_config")
    }

    @Test("OccurrencesResponse (hand-written)") func occurrencesResponse() throws {
        try assertRoundTrip(OccurrencesResponse.self, fixture: "occurrences_response")
    }

    @Test("Item") func item() throws { try assertRoundTrip(Item.self, fixture: "item") }

    @Test("Metadata") func metadata() throws { try assertRoundTrip(Metadata.self, fixture: "metadata") }

    @Test("Version") func version() throws { try assertRoundTrip(Version.self, fixture: "version") }

    @Test("ApiKey") func apiKey() throws { try assertRoundTrip(ApiKey.self, fixture: "api_key") }

    @Test("CreatedKey") func createdKey() throws { try assertRoundTrip(CreatedKey.self, fixture: "created_key") }

    @Test("Webhook") func webhook() throws { try assertRoundTrip(Webhook.self, fixture: "webhook") }

    @Test("WebhookDelivery") func webhookDelivery() throws {
        try assertRoundTrip(WebhookDelivery.self, fixture: "webhook_delivery")
    }

    @Test("AuditEntry") func auditEntry() throws {
        try assertRoundTrip(AuditEntry.self, fixture: "audit_entry")
    }

    @Test("BlobUploadResponse") func blobUploadResponse() throws {
        try assertRoundTrip(BlobUploadResponse.self, fixture: "blob_upload_response")
    }

    @Test("PresignedURLResponse") func presignedURLResponse() throws {
        try assertRoundTrip(PresignedURLResponse.self, fixture: "presigned_url_response")
    }

    @Test("TypeSchema") func typeSchema() throws {
        try assertRoundTrip(TypeSchema.self, fixture: "type_schema")
    }

    @Test("ConflictResponse") func conflictResponse() throws {
        try assertRoundTrip(ConflictResponse.self, fixture: "conflict_response")
    }

    @Test("PaginatedResult<Item> (hand-written)") func paginatedItems() throws {
        try assertRoundTrip(PaginatedResult<Item>.self, fixture: "paginated_items")
    }

    @Test("Edge") func edge() throws { try assertRoundTrip(Edge.self, fixture: "edge") }

    @Test("EdgeType") func edgeType() throws { try assertRoundTrip(EdgeType.self, fixture: "edge_type") }
}
