import Foundation
import MarfaTypes
import Testing

@Test func aPageOfItemsReadsEachRow() throws {
    let item =
        #"{"id":"i1","type":"core.note","state":"active","tier":"library","properties":{"title":"A note"},"created_at":"2026-09-24T00:00:00Z","updated_at":"2026-09-24T00:00:00Z","occurred_at":"2026-09-24T00:00:00Z","version":1,"source":"s","read_only":false,"schema_version":1}"#
    let page = try JSONDecoder().decode(
        Components.Schemas.ItemPage.self, from: Data(#"{"data":[\#(item)],"next_cursor":null}"#.utf8))
    guard case .Item(let row)? = page.data.first else {
        Issue.record("the row read as \(String(describing: page.data.first))")
        return
    }
    #expect(row.id == "i1")
    #expect(row.schemaVersion == 1)
    #expect(page.nextCursor == nil)
    let next = try JSONDecoder().decode(
        Components.Schemas.ItemPage.self, from: Data(#"{"data":[],"next_cursor":"c1"}"#.utf8))
    #expect(next.nextCursor == "c1")
}

private let live: (url: URL, key: String)? = {
    let environment = ProcessInfo.processInfo.environment
    // The same reading as `Server.fromEnvironment`, which this target cannot import.
    guard let text = environment["MARFA_API_URL"], !text.isEmpty, let key = environment["MARFA_API_KEY"], !key.isEmpty,
        let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
        !(url.host() ?? "").isEmpty
    else { return nil }
    return (url, key)
}()

@Test(.enabled(if: ProcessInfo.processInfo.environment["MARFA_LIVE_REQUIRED"] != nil))
func theLiveTestHasAServerWhereItIsRequired() {
    #expect(live != nil, "MARFA_LIVE_REQUIRED is set, and MARFA_API_URL or MARFA_API_KEY is not")
}

@Test(.enabled(if: live != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"))
func thePinnedServerAnswersInTheseTypes() async throws {
    let (url, key) = try #require(live)
    let (rootBody, _) = try await URLSession.shared.data(from: url)
    let root = try JSONDecoder().decode(Components.Schemas.InstanceDescription.self, from: rootBody)
    #expect(root.contract == marfaContractVersion)

    let title = "Wire \(UUID())"
    var create = URLRequest(url: url.appending(path: "items"))
    create.httpMethod = "POST"
    create.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    create.setValue("application/json", forHTTPHeaderField: "Content-Type")
    create.httpBody = Data(#"{"type":"core.note","properties":{"title":"\#(title)","body":""}}"#.utf8)
    let (_, created) = try await URLSession.shared.data(for: create)
    try #require((created as? HTTPURLResponse)?.statusCode == 201)

    let items = url.appending(path: "items").appending(queryItems: [
        .init(name: "type", value: "core.note"), .init(name: "limit", value: "100"),
    ])
    var request = URLRequest(url: items)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let (pageBody, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Marfa-Contract")
    #expect(header == String(marfaContractVersion))
    let page = try JSONDecoder().decode(Components.Schemas.ItemPage.self, from: pageBody)
    let titles = page.data.compactMap { row -> String? in
        guard case .Item(let item) = row else { return nil }
        return item.properties.additionalProperties["title"].flatMap { $0.value as? String }
    }
    #expect(titles.contains(title), "the page read as \(page.data.count) row(s), none the note sent")
}

@Test func previouslySkippedFieldsDecodeNullAndValues() throws {
    let decoder = JSONDecoder()
    let connector = try decoder.decode(
        Components.Schemas.Connector.self,
        from: Data(
            #"{"id":"c","key_id":"k","source":"s","name":"n","description":null,"registered_at":"now","updated_at":"now","last_heartbeat_at":null,"hold_expires_at":null,"last_run":null,"problems":{},"read_only_types":[]}"#
                .utf8))
    #expect(connector.lastRun == .null)
    let run = try decoder.decode(
        Components.Schemas.MarfaNullableConnectorRun.self,
        from: Data(
            #"{"id":"r","connector_id":"c","outcome":"succeeded","started_at":"now","finished_at":"now","summary":null,"error":null,"reported_at":"now"}"#
                .utf8))
    #expect(run.value?.id == "r")
    let job = try decoder.decode(
        Components.Schemas.HousekeepingJob.self,
        from: Data(
            #"{"name":"j","interval_ms":1,"next_run_at":"now","running_since":null,"last_started_at":null,"last_finished_at":null,"last_outcome":"ok","last_error":null,"last_result":{"count":2}}"#
                .utf8))
    #expect(job.lastOutcome.value == .ok)
    #expect(job.lastResult.value?.value["count"] as? Int == 2)
    let housekeepingRun = try decoder.decode(
        Components.Schemas.HousekeepingRun.self,
        from: Data(
            #"{"name":"j","started_at":"now","finished_at":"now","outcome":"ok","result":null,"error":null}"#.utf8))
    #expect(housekeepingRun.result == .null)
    #expect(throws: DecodingError.self) {
        try decoder.decode(MarfaNullValue.self, from: Data("false".utf8))
    }
}

@Test func anOverrideUpdateDistinguishesOmissionSettingAndClearing() throws {
    typealias Patch = Operations.UpdateKey.Input.Body.JsonPayload
    func object(_ patch: Patch) throws -> [String: Any] {
        let data = try JSONEncoder().encode(patch)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }
    #expect(try object(Patch())["enforcement_override"] == nil)
    let clear = Patch(enforcementOverride: .null)
    #expect(try object(clear)["enforcement_override"] is NSNull)
    let decodedClear = try JSONDecoder().decode(Patch.self, from: Data(#"{"enforcement_override":null}"#.utf8))
    #expect(decodedClear.enforcementOverride == .some(.null))
    #expect(try object(decodedClear)["enforcement_override"] is NSNull)
    let set = Patch(enforcementOverride: .value(.init(strictMode: .init(types: ["core.note"]))))
    let override = try #require(try object(set)["enforcement_override"] as? [String: Any])
    let strict = try #require(override["strict_mode"] as? [String: Any])
    #expect(strict["types"] as? [String] == ["core.note"])
}

@Test(.enabled(if: live != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"))
func nullableWireFieldsRoundTripThroughTheServer() async throws {
    let (url, key) = try #require(live)
    func send(_ method: String, _ path: String, _ body: Data? = nil, status: Int = 200) async throws -> Data {
        var request = URLRequest(url: url.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == status)
        return data
    }
    let jobs = try JSONDecoder().decode(
        Components.Schemas.HousekeepingJobPage.self, from: await send("GET", "housekeeping"))
    #expect(!jobs.data.isEmpty)
    let source = "wire-\(UUID().uuidString.lowercased())"
    let made = try JSONDecoder().decode(
        Components.Schemas.KeyResponse.self,
        from: await send(
            "POST", "keys",
            Data(#"{"label":"Wire test","source":"\#(source)","type_permissions":{"core.note":"write"}}"#.utf8),
            status: 201))
    typealias Patch = Operations.UpdateKey.Input.Body.JsonPayload
    let path = "keys/\(made.id)"
    do {
        let set = Patch(enforcementOverride: .value(.init(strictMode: .init(types: ["core.note"]))))
        let applied = try JSONDecoder().decode(
            Components.Schemas.ApiKey.self, from: await send("PATCH", path, JSONEncoder().encode(set)))
        #expect(applied.enforcementOverride?.strictMode?.types == ["core.note"])
        let omitted = try JSONDecoder().decode(
            Components.Schemas.ApiKey.self,
            from: await send("PATCH", path, JSONEncoder().encode(Patch(label: "Still set"))))
        #expect(omitted.enforcementOverride?.strictMode?.types == ["core.note"])
        let cleared = try JSONDecoder().decode(
            Components.Schemas.ApiKey.self,
            from: await send("PATCH", path, JSONEncoder().encode(Patch(enforcementOverride: .null))))
        #expect(cleared.enforcementOverride == nil)
        _ = try await send("DELETE", path)
    } catch {
        _ = try? await send("DELETE", path)
        throw error
    }
}

@Test func ordinaryKeyWireTypesHaveNoPrivilegedFlag() throws {
    let body = Data(
        #"{"id":"k1","key":"marfa_k1_fixture","label":"Fixture","source":"wire-fixture","sources":[],"permissions":[],"default_tier":"library","type_permissions":{},"extension_permissions":{},"edge_permissions":{},"metadata_permissions":{},"profile_permissions":{},"created_at":"2026-10-08T00:00:00Z","last_used_at":null}"#
            .utf8)
    let decoder = JSONDecoder()
    let created = try decoder.decode(Components.Schemas.KeyResponse.self, from: body)
    let held = try decoder.decode(Components.Schemas.ApiKey.self, from: body)
    #expect(created.id == held.id)
    for encoded in [try JSONEncoder().encode(created), try JSONEncoder().encode(held)] {
        let fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["is_operator"] == nil)
    }
}

@Test func everyNamedPermissionDecodes() throws {
    let names = [
        "schema.write", "keys.mint", "items.purge", "webhooks.manage", "config.manage", "audit.read", "grants.manage",
        "instance.read", "instance.maintain", "connectors.manage", "blobs.manage", "keys.manage",
    ]
    let decoded = try JSONDecoder().decode([Components.Schemas.Permission].self, from: JSONEncoder().encode(names))
    #expect(decoded.map(\.rawValue) == names)
    #expect(Set(Components.Schemas.Permission.allCases.map(\.rawValue)) == Set(names))
}

@Test func ownerPasskeyCursorRequiresAndRoundTripsNull() throws {
    let decoder = JSONDecoder()
    let list = try decoder.decode(
        Components.Schemas.OwnerPasskeyList.self, from: Data(#"{"data":[],"next_cursor":null}"#.utf8))
    #expect(list.nextCursor == .null)
    let encoded = try JSONEncoder().encode(list)
    let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(fields["next_cursor"] is NSNull)
    #expect(throws: DecodingError.self) {
        try decoder.decode(Components.Schemas.OwnerPasskeyList.self, from: Data(#"{"data":[]}"#.utf8))
    }
}

@Test(arguments: ["true", "0", #""cursor""#, "[]", "{}"])
func ownerPasskeyCursorRejectsNonNull(value: String) {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            Components.Schemas.OwnerPasskeyList.self, from: Data("{\"data\":[],\"next_cursor\":\(value)}".utf8))
    }
}

private struct NullOnlyFields: Codable {
    var required: MarfaNullValue
    var optional: MarfaNullValue?
}

@Test func optionalNullOnlyFieldKeepsNullDistinctFromAbsence() throws {
    let decoder = JSONDecoder()
    let omitted = try decoder.decode(NullOnlyFields.self, from: Data(#"{"required":null}"#.utf8))
    #expect(omitted.required == .null)
    #expect(omitted.optional == nil)
    let present = try decoder.decode(
        NullOnlyFields.self, from: Data(#"{"required":null,"optional":null}"#.utf8))
    #expect(present.optional == .null)
    let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(present)) as? [String: Any])
    #expect(fields["required"] is NSNull)
    #expect(fields["optional"] is NSNull)
    #expect(throws: DecodingError.self) {
        try decoder.decode(NullOnlyFields.self, from: Data(#"{"optional":null}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(NullOnlyFields.self, from: Data(#"{"required":null,"optional":false}"#.utf8))
    }
}

@Test(arguments: [
    (#"{"kind":"browser","id":"s1","name":"Safari"}"#, "s1"),
    (#"{"kind":"server","id":"server","name":"Marfa"}"#, "server"),
    ("null", nil as String?),
])
func anAuditActorDecodesAsEitherSignInShapeOrNull(actor: String, id: String?) throws {
    let wire =
        #"{"actor":\#(actor),"id":"a","created_at":"now","key_id":null,"action":"owner.claimed","#
        + #""resource_type":"owner","resource_id":null,"client_ip":null,"details":{}}"#
    let entry = try JSONDecoder().decode(Components.Schemas.AuditEntry.self, from: Data(wire.utf8))
    let kept = entry.actor.value
    #expect((kept?.value1?.id ?? kept?.value2?.id.rawValue) == id)
    #expect((entry.actor == .null) == (id == nil))
    let encoded = try JSONEncoder().encode(entry)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["actor"] is NSNull == (id == nil))
    #expect(try JSONDecoder().decode(Components.Schemas.AuditEntry.self, from: encoded) == entry)
}

@Test(arguments: ["", #""actor":{"kind":"server"},"#, #""actor":"Safari","#])
func anAuditEntryRequiresAnActorOfTheDocumentedShape(actor: String) {
    let wire =
        "{" + actor + #""id":"a","created_at":"now","key_id":null,"action":"owner.claimed","#
        + #""resource_type":"owner","resource_id":null,"client_ip":null,"details":{}}"#
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Components.Schemas.AuditEntry.self, from: Data(wire.utf8))
    }
}
