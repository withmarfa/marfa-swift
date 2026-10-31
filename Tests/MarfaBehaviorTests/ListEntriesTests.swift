#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Testing

/// A list field whose entries are objects, on both copies.
@Suite(.timeLimit(.minutes(1)))
struct ListEntries {
    static let contact: JSONObject = [
        "id": "app.test.contact",
        "fields": [
            "name": ["type": "string", "required": true],
            "phones": [
                "type": "array", "items_type": "object",
                "items_fields": [
                    "number": ["type": "string", "required": true],
                    "kind": ["type": "enum", "enum_values": ["home", "work"]],
                    "preferred": ["type": "boolean"],
                    "rank": ["type": "integer"],
                    "weight": ["type": "number"],
                ],
            ],
        ],
    ]

    static func refused(_ message: String) -> (any Error) -> Bool {
        { error in
            if case .validation("invalid_properties", let given)? = error as? MarfaError {
                given.hasSuffix("phones: Item 0: \(message)")
            } else {
                false
            }
        }
    }

    static func create(_ copy: WorkingCopy, phones: JSONValue) async throws {
        try await copy.declareTypes([contact])
        _ = try await copy.items.create(Draft(type: "app.test.contact", properties: ["name": "Ada", "phones": phones]))
    }

    @Test(arguments: CopyKind.allCases)
    func aListOfEntriesTheMembersAllowIsSaved(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let phones: JSONValue = [
            ["number": "020 7946 0000", "kind": "work", "preferred": true, "rank": 1, "weight": 0.5],
            ["number": "020 7946 0001"],
        ]
        try await Self.create(copy, phones: phones)
        let saved = try await copy.items.list(ListFilters(types: ["app.test.contact"]))
        #expect(saved.first?.properties["phones"] == phones)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aListOfEntriesCanBeEmpty(kind: CopyKind) async throws {
        let copy = try await kind.open()
        try await Self.create(copy, phones: [])
        await copy.close()
    }

    @Test(
        arguments: CopyKind.allCases,
        [
            (["number": "1", "kind": "mobile"], "kind: Must be one of \"home\", \"work\""),
            (["number": 1], "number: Expected string"),
            (["kind": "home"], "number: Required"),
            (["number": "1", "email": "a@b.c"], "email: Is not a member of the entry"),
            ([:], "Must have at least one member"),
            (["number": "1", "preferred": "yes"], "preferred: Expected boolean"),
            (["number": "1", "rank": 1.5], "rank: Expected safe integer"),
            (["number": "1", "weight": "heavy"], "weight: Expected number"),
            (["number": "a\u{0}b"], "number: Must not contain a null byte (U+0000)"),
        ] as [(JSONObject, String)])
    func anEntryTheMembersRefuseIsRefusedAsTheCoreRefusesIt(
        kind: CopyKind, entry: (JSONObject, String)
    ) async throws {
        let copy = try await kind.open()
        await #expect(
            performing: {
                try await Self.create(copy, phones: .array([.object(entry.0)]))
            }, throws: Self.refused(entry.1))
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aListThatIsNotAListIsRefused(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await #expect {
            try await Self.create(copy, phones: "020 7946 0000")
        } throws: { error in
            if case .validation("invalid_properties", let given)? = error as? MarfaError {
                given.hasSuffix("phones: Expected array")
            } else {
                false
            }
        }
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEntryThatIsNotAnObjectIsRefused(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await #expect(
            performing: {
                try await Self.create(copy, phones: ["020 7946 0000"])
            }, throws: Self.refused("Expected object"))
        await copy.close()
    }

    @Test func aMemberTheFakeCannotJudgeIsUnsupportedNotAnsweredDifferently() async throws {
        let copy = WorkingCopy.fake().copy
        try await copy.declareTypes([
            [
                "id": "app.test.contact",
                "fields": [
                    "emails": [
                        "type": "array", "items_type": "object",
                        "items_fields": ["address": ["type": "email"]],
                    ]
                ],
            ]
        ])
        await #expect {
            _ = try await copy.items.create(
                Draft(type: "app.test.contact", properties: ["emails": [["address": "ada@example.com"]]]))
        } throws: { error in
            guard case .unsupported(let call)? = error as? FakeCopyError else { return false }
            return call.contains("email member")
        }
        await copy.close()
    }
}
#endif
