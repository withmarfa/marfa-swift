import Testing
import Foundation
@testable import MarfaCodegenCore

/// The two `system.*` models the SDK ships are hand-written, and until now
/// nothing compared them against the schemas they mirror.
///
/// They are hand-written deliberately: the domain-model generator emits an
/// enum-typed schema field as a bare `String?`, and `ConnectionKind` and
/// `ActivitySeverity` being closed enums is the whole reason these two exist
/// as typed models rather than raw items. Generating them would be a
/// downgrade of the public surface, not a simplification.
///
/// What that costs is a drift risk, and the cost used to be unbounded: the
/// system schemas were never vendored into this repository at all, so a
/// field added upstream was invisible here — the freshness job compares
/// generated output against a snapshot, and a namespace absent from the
/// snapshot is a namespace the job structurally cannot see. The schemas are
/// vendored now, and this is what reads them.
///
/// A failure here is not a bug in the model. It means the schema moved, and
/// the answer is to add the accessor (or decide out loud that the field has
/// no place on the typed surface and list it below).
@Suite("System models track their schemas")
struct SystemSchemaDriftTests {

    /// Fields deliberately absent from the typed surface, with the reason.
    /// Empty today; an entry here is a decision, not a backlog.
    private static let deliberatelyUnexposed: [String: Set<String>] = [:]

    /// The package root, walked up from this file. The vendored snapshot is
    /// read from source rather than from a resource bundle: it belongs to the
    /// codegen library's bundle, not this test target's, and a drift test
    /// wants the file the sync script writes anyway.
    private var packageRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return root
    }

    private func schemaFields(_ id: String) throws -> Set<String> {
        let file = packageRoot
            .appendingPathComponent("scripts/MarfaCodegenCore/core-types/system")
            .appendingPathComponent(id.replacingOccurrences(of: "system.", with: "") + ".json")
        let data = try Data(contentsOf: file)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = json["fields"] as? [String: Any] ?? [:]
        return Set(fields.keys)
    }

    /// Property keys a model reads, taken from the model source rather than
    /// from a second hand-maintained list — a list would drift in exactly the
    /// way this test exists to catch.
    private func exposedKeys(inModelNamed name: String) throws -> Set<String> {
        let source = packageRoot
            .appendingPathComponent("Sources/MarfaSDK/DomainModels/System")
            .appendingPathComponent("\(name).swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        var keys: Set<String> = []
        // `item.properties["<key>"]` is the one way these models read a field.
        let pattern = #"item\.properties\["([a-z0-9_]+)"\]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            keys.insert(String(text[r]))
        }
        return keys
    }

    @Test("system.connection exposes every field its schema declares")
    func connectionTracksSchema() throws {
        let declared = try schemaFields("system.connection")
        let exposed = try exposedKeys(inModelNamed: "Connection")
        let unexposed = declared
            .subtracting(exposed)
            .subtracting(Self.deliberatelyUnexposed["system.connection"] ?? [])
        #expect(
            unexposed.isEmpty,
            "system.connection declares fields the Connection model does not read: \(unexposed.sorted())"
        )
        // The reverse too: a model reading a key the schema dropped is dead
        // code that will quietly always be nil.
        let stale = exposed.subtracting(declared)
        #expect(
            stale.isEmpty,
            "Connection reads keys system.connection no longer declares: \(stale.sorted())"
        )
    }

    @Test("system.activity exposes every field its schema declares")
    func activityTracksSchema() throws {
        let declared = try schemaFields("system.activity")
        let exposed = try exposedKeys(inModelNamed: "Activity")
        let unexposed = declared
            .subtracting(exposed)
            .subtracting(Self.deliberatelyUnexposed["system.activity"] ?? [])
        #expect(
            unexposed.isEmpty,
            "system.activity declares fields the Activity model does not read: \(unexposed.sorted())"
        )
        let stale = exposed.subtracting(declared)
        #expect(
            stale.isEmpty,
            "Activity reads keys system.activity no longer declares: \(stale.sorted())"
        )
    }

    @Test("every system schema is vendored, so nothing new is invisible")
    func everySystemSchemaIsVendored() throws {
        let systemDir = packageRoot
            .appendingPathComponent("scripts/MarfaCodegenCore/core-types/system")
        let files = try FileManager.default
            .contentsOfDirectory(at: systemDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        // Not an exact count: the point is that the directory is populated
        // and the sync script reaches it, so a schema added upstream lands
        // here on the next sync instead of never.
        #expect(files.count >= 8)
        #expect(files.contains { $0.lastPathComponent == "connection.json" })
        #expect(files.contains { $0.lastPathComponent == "activity.json" })
    }
}
