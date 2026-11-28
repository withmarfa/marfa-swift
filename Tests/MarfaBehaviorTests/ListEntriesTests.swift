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
            if case .validation("invalid_properties", let given, _, _)? = error as? MarfaError {
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
            (["number": "1", "rank": 1.5], "rank: Expected a whole number from -9007199254740991 to 9007199254740991"),
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
            if case .validation("invalid_properties", let given, _, _)? = error as? MarfaError {
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

    static let addresses: JSONObject = [
        "id": "app.test.addressbook",
        "fields": [
            "emails": [
                "type": "array", "items_type": "object",
                "items_fields": [
                    "value": ["type": "email", "required": true],
                    "label": ["type": "string"],
                ],
            ]
        ],
    ]

    static func createAddresses(_ copy: WorkingCopy, emails: JSONValue) async throws {
        try await copy.declareTypes([addresses])
        _ = try await copy.items.create(Draft(type: "app.test.addressbook", properties: ["emails": emails]))
    }

    @Test(arguments: CopyKind.allCases)
    func anEntryWithAValidEmailMemberIsSaved(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let emails: JSONValue = [["value": "reader+tag@example.test", "label": "work"], ["value": "a.b@example.test"]]
        try await Self.createAddresses(copy, emails: emails)
        let saved = try await copy.items.list(ListFilters(types: ["app.test.addressbook"]))
        #expect(saved.first?.properties["emails"] == emails)
        await copy.close()
    }

    @Test(
        arguments: CopyKind.allCases,
        [
            "nobody", "a..b@example.test", "a.@example.test", ".a@example.test", "a@localhost", "a@domain.t",
            "a@-domain.test", "\u{FC}@example.test", "a@\u{4F8B}\u{5B50}.test", "", "a@b@example.test",
        ])
    func anEntryWithAnInvalidEmailMemberIsRefusedAsTheCoreRefusesIt(kind: CopyKind, address: String) async throws {
        let copy = try await kind.open()
        await #expect {
            try await Self.createAddresses(copy, emails: [["value": .string(address)]])
        } throws: { error in
            if case .validation("invalid_properties", let given, _, _)? = error as? MarfaError {
                given.hasSuffix("emails: Item 0: value: Must be a valid email address")
            } else {
                false
            }
        }
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEntryThatLeavesOutARequiredEmailMemberIsRefused(kind: CopyKind) async throws {
        let copy = try await kind.open()
        await #expect {
            try await Self.createAddresses(copy, emails: [["label": "work"]])
        } throws: { error in
            if case .validation("invalid_properties", let given, _, _)? = error as? MarfaError {
                given.hasSuffix("emails: Item 0: value: Required")
            } else {
                false
            }
        }
        await copy.close()
    }

    static let events: JSONObject = [
        "id": "app.test.events",
        "fields": [
            "slots": [
                "type": "array", "items_type": "object",
                "items_fields": [
                    "day": ["type": "date"], "start": ["type": "datetime"],
                ],
            ]
        ],
    ]

    static func createSlot(_ copy: WorkingCopy, slot: JSONObject) async throws {
        try await copy.declareTypes([events])
        _ = try await copy.items.create(Draft(type: "app.test.events", properties: ["slots": [.object(slot)]]))
    }

    @Test(arguments: CopyKind.allCases)
    func anEntryWithDateAndDatetimeMembersIsSaved(kind: CopyKind) async throws {
        let copy = try await kind.open()
        for slot: JSONObject in [
            ["day": "2028-02-29", "start": "2026-01-01T09:30Z"],
            ["start": "2026-01-01T09:30:15.5+05:30"], ["start": "2026-01-01"],
        ] {
            try await Self.createSlot(copy, slot: slot)
        }
        await copy.close()
    }

    @Test(
        arguments: CopyKind.allCases,
        [
            (["day": "2027-02-29"], "day: Must be a calendar date (YYYY-MM-DD)"),
            (["day": "2026-1-01"], "day: Must be a calendar date (YYYY-MM-DD)"),
            (["day": 20_260_101], "day: Must be a calendar date (YYYY-MM-DD)"),
            (["start": "2026-01-01T24:00Z"], "start: Must be a calendar date or ISO 8601 datetime with an offset"),
            (["start": "2026-01-01T00:00"], "start: Must be a calendar date or ISO 8601 datetime with an offset"),
            (["start": "2026-01-01T00:00:00.Z"], "start: Must be a calendar date or ISO 8601 datetime with an offset"),
            (["start": "2026-01-01T00:00+24:00"], "start: Must be a calendar date or ISO 8601 datetime with an offset"),
        ] as [(JSONObject, String)])
    func aDateOrDatetimeMemberTheCoreRefusesIsRefusedAsTheCoreRefusesIt(
        kind: CopyKind, slot: (JSONObject, String)
    ) async throws {
        let copy = try await kind.open()
        await #expect {
            try await Self.createSlot(copy, slot: slot.0)
        } throws: { error in
            if case .validation("invalid_properties", let given, _, _)? = error as? MarfaError {
                given.hasSuffix("slots: Item 0: \(slot.1)")
            } else {
                false
            }
        }
        await copy.close()
    }

    @Test func aMemberTheFakeCannotJudgeIsUnsupportedNotAnsweredDifferently() async throws {
        let copy = WorkingCopy.fake().copy
        try await copy.declareTypes([
            [
                "id": "app.test.contact",
                "fields": [
                    "links": [
                        "type": "array", "items_type": "object",
                        "items_fields": ["address": ["type": "url"]],
                    ]
                ],
            ]
        ])
        await #expect {
            _ = try await copy.items.create(
                Draft(type: "app.test.contact", properties: ["links": [["address": "https://example.com"]]]))
        } throws: { error in
            guard case .unsupported(let call)? = error as? FakeCopyError else { return false }
            return call.contains("url member")
        }
        await copy.close()
    }
}
#endif
