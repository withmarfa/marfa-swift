#if DEBUG
import Foundation
import Marfa
import Testing

/// An edit removes the properties it names in `clearProperties` and keeps every other.
@Suite(.timeLimit(.minutes(1)))
struct ClearProperties {
    static let entry: JSONObject = [
        "id": "app.test.clearing",
        "fields": ["title": ["type": "string", "required": true], "notes": ["type": "string"]],
    ]

    static func open(_ kind: CopyKind) async throws -> (WorkingCopy, String, Int64) {
        let copy = try await kind.open(declaring: [entry])
        let made = try await copy.items.create(
            Draft(
                type: "app.test.clearing",
                properties: ["title": "kept", "notes": "to clear", "unknown": ["nested": [1, "x"]], "other": "stays"]))
        let id = try #require(made.itemId)
        let version = try #require(try await copy.items.get(id)).version
        return (copy, id, version)
    }

    static func refusedBeforeQueueing(
        _ copy: WorkingCopy, _ id: String, _ edit: Edit, code: String, naming name: String
    ) async throws {
        let before = try await copy.items.get(id)
        let queued = try await copy.queue.all().count
        await #expect {
            _ = try await copy.items.update(id, edit)
        } throws: { error in
            guard case MarfaError.validation(code, let message) = error else { return false }
            return message.contains(name)
        }
        #expect(try await copy.items.get(id) == before)
        #expect(try await copy.queue.all().count == queued)
    }

    @Test(arguments: CopyKind.allCases)
    func aClearRemovesOnlyTheNamedPropertiesAndSendsThem(kind: CopyKind) async throws {
        let (copy, id, version) = try await Self.open(kind)

        let queued = try await copy.items.update(
            id, Edit(clearProperties: ["notes", "unknown", "never-held"], baseVersion: version))

        let held = try #require(try await copy.items.get(id))
        #expect(held.properties == ["title": "kept", "other": "stays"])
        #expect(queued.body["properties"] == [:])
        #expect(queued.body["clear_properties"] == ["never-held", "notes", "unknown"])
        #expect(queued.body["properties_mode"] == nil)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aClearBesideASetLaysBoth(kind: CopyKind) async throws {
        let (copy, id, version) = try await Self.open(kind)

        _ = try await copy.items.update(
            id, Edit(properties: ["title": "changed"], clearProperties: ["notes"], baseVersion: version))

        #expect(
            try #require(try await copy.items.get(id)).properties == [
                "title": "changed", "unknown": ["nested": [1, "x"]], "other": "stays",
            ])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEditWithNoClearSendsNoClear(kind: CopyKind) async throws {
        let (copy, id, version) = try await Self.open(kind)

        let queued = try await copy.items.update(id, Edit(properties: ["notes": "new"], baseVersion: version))

        #expect(queued.body["clear_properties"] == nil)
        #expect(try #require(try await copy.items.get(id)).properties["notes"] == "new")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aNameBothSetAndClearedIsRefused(kind: CopyKind) async throws {
        let (copy, id, version) = try await Self.open(kind)
        try await Self.refusedBeforeQueueing(
            copy, id, Edit(properties: ["notes": "new"], clearProperties: ["notes"], baseVersion: version),
            code: "validation_error", naming: "notes")
        // A null still names the property, so it is refused the same way.
        try await Self.refusedBeforeQueueing(
            copy, id, Edit(properties: ["notes": nil], clearProperties: ["notes"], baseVersion: version),
            code: "validation_error", naming: "notes")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEmptyNameIsRefused(kind: CopyKind) async throws {
        let (copy, id, version) = try await Self.open(kind)
        try await Self.refusedBeforeQueueing(
            copy, id, Edit(clearProperties: [""], baseVersion: version), code: "validation_error",
            naming: "clear_properties")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aRequiredFieldIsRefusedThroughEitherUpdate(kind: CopyKind) async throws {
        let (copy, id, version) = try await Self.open(kind)
        try await Self.refusedBeforeQueueing(
            copy, id, Edit(clearProperties: ["title"], baseVersion: version), code: "invalid_properties",
            naming: "title")
        let before = try await copy.items.get(id)
        await #expect {
            _ = try await copy.items.updateAsRead(id, Edit(clearProperties: ["title"], baseVersion: version))
        } throws: { error in
            if case MarfaError.validation("invalid_properties", _) = error { true } else { false }
        }
        #expect(try await copy.items.get(id) == before)
        #expect(try await copy.queue.all().count == 1)

        // The witness: an optional field clears.
        _ = try await copy.items.update(id, Edit(clearProperties: ["notes"], baseVersion: version))
        #expect(try #require(try await copy.items.get(id)).properties["notes"] == nil)
        await copy.close()
    }
}
#endif
