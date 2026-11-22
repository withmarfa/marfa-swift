#if DEBUG
import Foundation
import Marfa
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DeclaredTypeTextOffline {
    /// A string of `count` Unicode code points that is half as many characters a person reads: each is a letter and
    /// a combining accent.
    static func accented(_ count: Int) -> String {
        String(repeating: "e\u{301}", count: count / 2) + (count.isMultiple(of: 2) ? "" : "e")
    }

    static func text(_ count: Int) -> JSONValue { .string(String(repeating: "x", count: count)) }

    static func declare(_ definition: JSONObject, on kind: CopyKind) async throws -> [JSONObject] {
        let copy = try await kind.open()
        defer { Task { await copy.close() } }
        try await copy.declareTypes([definition])
        return try await copy.declaredTypes()
    }

    static func isInvalid(_ error: any Error) -> Bool {
        if case MarfaError.invalid = error { true } else { false }
    }

    @Test(arguments: CopyKind.allCases, [201, 300])
    func aTypeDescriptionOverTwoHundredCodePointsIsRefused(kind: CopyKind, length: Int) async throws {
        await #expect {
            _ = try await Self.declare(["id": "app.review.entry", "description": Self.text(length)], on: kind)
        } throws: { Self.isInvalid($0) }
    }

    @Test(arguments: CopyKind.allCases)
    func aTypeDescriptionOfTwoHundredCodePointsIsKept(kind: CopyKind) async throws {
        let held = try await Self.declare(["id": "app.review.entry", "description": Self.text(200)], on: kind)
        #expect(held.first?["description"] == Self.text(200))
    }

    @Test(arguments: CopyKind.allCases)
    func aLimitCountsCodePointsNotCharacters(kind: CopyKind) async throws {
        let over = JSONValue.string(Self.accented(201))
        await #expect {
            _ = try await Self.declare(["id": "app.review.entry", "description": over], on: kind)
        } throws: { Self.isInvalid($0) }
        let at = JSONValue.string(Self.accented(200))
        let held = try await Self.declare(["id": "app.review.entry", "description": at], on: kind)
        #expect(held.first?["description"] == at)
        let wide = JSONValue.string(String(repeating: "\u{1F600}", count: 200))
        let kept = try await Self.declare(["id": "app.review.entry", "description": wide], on: kind)
        #expect(kept.first?["description"] == wide)
    }

    @Test(arguments: CopyKind.allCases, [JSONValue.integer(7), .null, .bool(false), .array([]), .object([:])])
    func aTypeDescriptionThatIsNotTextIsRefused(kind: CopyKind, description: JSONValue) async throws {
        await #expect {
            _ = try await Self.declare(["id": "app.review.entry", "description": description], on: kind)
        } throws: { Self.isInvalid($0) }
    }

    @Test(arguments: CopyKind.allCases)
    func aFieldDescriptionIsHeldToThreeHundredCodePoints(kind: CopyKind) async throws {
        func definition(_ length: Int) -> JSONObject {
            ["id": "app.review.entry", "fields": ["title": ["type": "string", "description": Self.text(length)]]]
        }
        await #expect {
            _ = try await Self.declare(definition(301), on: kind)
        } throws: { Self.isInvalid($0) }
        let held = try await Self.declare(definition(300), on: kind)
        #expect(held.first == definition(300).merging(["version": 0]))
    }

    @Test(arguments: CopyKind.allCases)
    func aMemberDescriptionIsHeldToThreeHundredCodePoints(kind: CopyKind) async throws {
        func definition(_ length: Int) -> JSONObject {
            [
                "id": "app.review.entry",
                "fields": [
                    "people": [
                        "type": "array", "items_type": "object",
                        "items_fields": ["name": ["type": "string", "description": Self.text(length)]],
                    ]
                ],
            ]
        }
        await #expect {
            _ = try await Self.declare(definition(301), on: kind)
        } throws: { Self.isInvalid($0) }
        _ = try await Self.declare(definition(300), on: kind)
    }

    @Test(arguments: CopyKind.allCases)
    func aStatusWordDescriptionOverOneHundredTwentyCodePointsIsRefused(kind: CopyKind) async throws {
        let definition: JSONObject = [
            "id": "app.review.entry",
            "fields": [
                "state": [
                    "type": "status",
                    "status_values": [["value": "open", "group": "not_started", "description": Self.text(121)]],
                ]
            ],
        ]
        await #expect {
            _ = try await Self.declare(definition, on: kind)
        } throws: { Self.isInvalid($0) }
    }

    @Test(arguments: CopyKind.allCases)
    func anAppTypeTakesNoGuidance(kind: CopyKind) async throws {
        await #expect {
            _ = try await Self.declare(["id": "app.review.entry", "guidance": "Use this type"], on: kind)
        } throws: { Self.isInvalid($0) }
    }

    @Test(arguments: CopyKind.allCases)
    func aGuidanceThatIsEmptyIsTakenOnAnAppType(kind: CopyKind) async throws {
        let held = try await Self.declare(["id": "app.review.entry", "guidance": ""], on: kind)
        #expect(held.count == 1)
    }

    @Test(arguments: CopyKind.allCases, [JSONValue.integer(7), .null, .bool(true), .array([]), .object([:])])
    func guidanceThatIsNotTextIsRefused(kind: CopyKind, guidance: JSONValue) async throws {
        await #expect {
            _ = try await Self.declare(["id": "app.review.entry", "guidance": guidance], on: kind)
        } throws: { Self.isInvalid($0) }
    }

    @Test(arguments: CopyKind.allCases)
    func aRefusedTextLeavesTheDeclarationsAsTheyWere(kind: CopyKind) async throws {
        let copy = try await kind.open()
        try await copy.declareTypes([["id": "app.review.entry"]])
        let before = try await copy.declaredTypes()
        await #expect {
            try await copy.declareTypes([["id": "app.review.entry", "description": Self.text(201)]])
        } throws: { Self.isInvalid($0) }
        #expect(try await copy.declaredTypes() == before)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases, ["backups.entry", "sign_ins.entry"])
    func aRootThatNamesAPermissionFamilyIsRefused(kind: CopyKind, id: String) async throws {
        await #expect {
            _ = try await Self.declare(["id": .string(id)], on: kind)
        } throws: { Self.isInvalid($0) }
    }
}

extension JSONObject {
    fileprivate func merging(_ other: JSONObject) -> JSONObject {
        var merged = self
        for member in other.members { merged[member.key] = member.value }
        return merged
    }
}
#endif
