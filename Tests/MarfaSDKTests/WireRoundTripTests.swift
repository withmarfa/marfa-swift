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

    // Hand-written, and the only wire model in this suite that is. The
    // generated ones are already guarded by the codegen freshness check;
    // the hand-written ones are the ones that drift, and this is where that
    // drift shows up as a dropped key rather than as a diff.
    @Test("SpaceConfig (hand-written)") func spaceConfig() throws {
        try assertRoundTrip(SpaceConfig.self, fixture: "space_config")
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

    @Test("ConflictResponse (hand-written)") func conflictResponse() throws {
        try assertRoundTrip(ConflictResponse.self, fixture: "conflict_response")
    }

    @Test("PaginatedResult<Item>") func paginatedItems() throws {
        try assertRoundTrip(PaginatedResult<Item>.self, fixture: "paginated_items")
    }

    @Test("Edge") func edge() throws { try assertRoundTrip(Edge.self, fixture: "edge") }

    @Test("EdgeType") func edgeType() throws { try assertRoundTrip(EdgeType.self, fixture: "edge_type") }
}
