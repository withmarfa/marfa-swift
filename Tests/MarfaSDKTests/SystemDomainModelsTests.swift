import Testing
import Foundation
@testable import MarfaSDK

@Suite("System domain models — Connection / Activity")
struct SystemDomainModelsTests {

    private func makeItem(
        type: String,
        properties: [String: JSONValue],
        id: String = "id-1"
    ) -> Item {
        Item(
            createdAt: "2026-05-01T00:00:00Z",
            id: id,
            properties: properties,
            schemaVersion: 1,
            source: "test",
            state: .active,
            timestamp: "2026-05-01T00:00:00Z",
            type: type,
            updatedAt: "2026-05-01T00:00:00Z",
            version: 1
        )
    }

    @Test("Connection wraps system.connection with required fields")
    func connectionRequiredFields() {
        let item = makeItem(
            type: "system.connection",
            properties: [
                "kind": .string("integration"),
                "granted_at": .string("2026-05-01T00:00:00Z"),
                "integration_ref": .string("int-1"),
                "scopes": .array([.string("read"), .string("write")])
            ]
        )
        let connection = Connection(from: item)
        #expect(connection != nil)
        #expect(connection?.kind == .integration)
        #expect(connection?.integrationRef == "int-1")
        #expect(connection?.scopes == ["read", "write"])
    }

    @Test("Connection rejects items of the wrong type")
    func connectionWrongType() {
        let item = makeItem(
            type: "core.note",
            properties: ["kind": .string("app"), "granted_at": .string("x")]
        )
        #expect(Connection(from: item) == nil)
    }

    @Test("Connection rejects when required fields are missing")
    func connectionMissingFields() {
        let item = makeItem(
            type: "system.connection",
            properties: ["kind": .string("app")]  // missing granted_at
        )
        #expect(Connection(from: item) == nil)
    }

    @Test("Connection.kind defaults to .integration on unknown values")
    func connectionUnknownKind() {
        let item = makeItem(
            type: "system.connection",
            properties: [
                "kind": .string("future-kind"),
                "granted_at": .string("2026-05-01T00:00:00Z")
            ]
        )
        let connection = Connection(from: item)
        // Falls back rather than crashing — apps see `.integration` and
        // can route the unknown gracefully.
        #expect(connection?.kind == .integration)
    }

    @Test("Activity wraps system.activity with severity, summary, connection_id")
    func activityRequiredFields() {
        let item = makeItem(
            type: "system.activity",
            properties: [
                "connection_id": .string("conn-1"),
                "severity": .string("action_required"),
                "summary": .string("Re-authorise the calendar integration")
            ]
        )
        let activity = Activity(from: item)
        #expect(activity != nil)
        #expect(activity?.severity == .actionRequired)
        #expect(activity?.connectionId == "conn-1")
        #expect(activity?.summary.contains("Re-authorise") == true)
    }

    @Test("Activity rejects missing severity")
    func activityMissingSeverity() {
        let item = makeItem(
            type: "system.activity",
            properties: [
                "connection_id": .string("conn-1"),
                "summary": .string("x")
            ]
        )
        #expect(Activity(from: item) == nil)
    }

    @Test("ConnectionKind decodes app | integration | tenant verbatim from JSON")
    func connectionKindJSON() throws {
        let app = try JSONDecoder().decode(ConnectionKind.self, from: Data(#""app""#.utf8))
        let integration = try JSONDecoder().decode(ConnectionKind.self, from: Data(#""integration""#.utf8))
        let tenant = try JSONDecoder().decode(ConnectionKind.self, from: Data(#""tenant""#.utf8))
        #expect(app == .app)
        #expect(integration == .integration)
        #expect(tenant == .tenant)
    }

    @Test("ActivitySeverity rawValue matches snake_case wire spelling")
    func activitySeverityWireSpelling() throws {
        let actionReq = try JSONDecoder().decode(
            ActivitySeverity.self,
            from: Data(#""action_required""#.utf8)
        )
        #expect(actionReq == .actionRequired)
        let encoded = try JSONEncoder().encode(ActivitySeverity.actionRequired)
        #expect(String(data: encoded, encoding: .utf8) == #""action_required""#)
    }
}
