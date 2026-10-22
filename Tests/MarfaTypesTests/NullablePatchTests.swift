import Foundation
import MarfaTypes
import Testing

private func expectPatchRoundTrip<Patch: Codable>(_ type: Patch.Type, wire: String) throws {
    let data = Data(wire.utf8)
    let patch = try JSONDecoder().decode(type, from: data)
    let encoded = try JSONEncoder().encode(patch)
    let expected = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let actual = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(NSDictionary(dictionary: actual).isEqual(to: expected))
}

@Test(arguments: ["{}", #"{"avatar":null}"#])
func nullablePatchAvatarKeepsOmissionAndNull(wire: String) throws {
    try expectPatchRoundTrip(Operations.UpdateProfile.Input.Body.JsonPayload.self, wire: wire)
}

@Test(arguments: ["{}", #"{"expires_at":null}"#, #"{"expires_at":"2026-12-01T00:00:00.000Z"}"#])
func nullablePatchExpiryKeepsOmissionNullAndValue(wire: String) throws {
    try expectPatchRoundTrip(Operations.UpdateKey.Input.Body.JsonPayload.self, wire: wire)
}

@Test(arguments: ["{}", #"{"type_filter":null}"#, #"{"type_filter":"core.note"}"#])
func nullablePatchWebhookKeepsOmissionNullAndValue(wire: String) throws {
    try expectPatchRoundTrip(Operations.UpdateWebhook.Input.Body.JsonPayload.self, wire: wire)
}

@Test func nullablePatchConstructorsCanSetAndClearValues() throws {
    typealias Profile = Operations.UpdateProfile.Input.Body.JsonPayload
    typealias Key = Operations.UpdateKey.Input.Body.JsonPayload
    typealias Webhook = Operations.UpdateWebhook.Input.Body.JsonPayload
    let encoder = JSONEncoder()
    for (field, encoded) in [
        ("avatar", try encoder.encode(Profile(avatar: .null))),
        ("expires_at", try encoder.encode(Key(expiresAt: .null))),
        ("type_filter", try encoder.encode(Webhook(typeFilter: .null))),
    ] {
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields[field] is NSNull)
    }
    let webhook = Webhook(typeFilter: .value("core.note"))
    let fields = try #require(JSONSerialization.jsonObject(with: encoder.encode(webhook)) as? [String: Any])
    #expect(fields["type_filter"] as? String == "core.note")
}

@Test(arguments: ["{}", #"{"feed_days":null}"#, #"{"feed_days":30}"#])
func nullableRetentionKeepsOmissionNullAndValue(wire: String) throws {
    try expectPatchRoundTrip(Components.Schemas.RetentionPolicy.self, wire: wire)
}
