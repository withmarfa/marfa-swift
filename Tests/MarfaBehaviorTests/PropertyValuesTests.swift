#if DEBUG
import Foundation
import Marfa
import Testing

/// Properties cross the binding as values.
///
/// Every test works on a copy that has never reached a server, and none reads
/// or writes the keychain. The tests that need a store reopened, damaged or
/// read by search stay with the real copy in `PropertyValues`.
@Suite(.timeLimit(.minutes(1)))
struct PropertyValuesOffline {
    static let entry: JSONObject = [
        "id": "app.test.entry", "fields": ["title": ["type": "string"]],
    ]

    /// A copy with an app type that declares one field, so a property it does
    /// not declare is one the app has never seen.
    static func open(_ kind: CopyKind) async throws -> WorkingCopy {
        try await kind.open(declaring: [entry])
    }

    static func create(_ copy: WorkingCopy, _ properties: JSONObject) async throws -> String {
        try #require(try await copy.items.create(Draft(type: "app.test.entry", properties: properties)).itemId)
    }

    @Test(arguments: CopyKind.allCases)
    func propertiesOfEveryJSONKindComeBackAsTheValuesTheyWere(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let properties: JSONObject = [
            "title": "caf\u{e9} \u{1F600} \u{2028} \"quoted\"\n",
            "nothing": nil, "yes": true, "no": false,
            "small": -7, "beyond": .integer(1_152_921_504_606_847_000), "least": .integer(-1_152_921_504_606_847_000),
            "ratio": 0.1, "tiny": 1e-300,
            "list": [1, [2, [3, ["deep": [nil, "x"]]]]], "empty": [:], "none": [],
        ]
        let id = try await Self.create(copy, properties)
        let held = try #require(try await copy.items.get(id))
        #expect(held.unreadableProperties == nil)
        #expect(held.properties == properties)
        #expect(held.properties["beyond"] == .integer(1_152_921_504_606_847_000))
        #expect(held.properties["least"] == .integer(-1_152_921_504_606_847_000))
        #expect(held.properties["ratio"] == .number(0.1))
        #expect(held.properties["nothing"] == .null)
        #expect(held.properties["list"]?.array?[1].array?[1].array?[1].object?["deep"]?.array?.count == 2)
        let listed = try #require(try await copy.items.list().first)
        #expect(listed.properties == properties)
        let queued = try #require(try await copy.queue.all().first)
        #expect(queued.body["properties"]?.object == properties)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aDraftAndAnEditThatNameNoPropertiesCrossAsAnEmptyObject(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let made = try await copy.items.create(Draft(type: "app.test.entry"))
        let id = try #require(made.itemId)
        let held = try #require(try await copy.items.get(id))
        #expect(held.properties.isEmpty)
        #expect(held.unreadableProperties == nil)
        let moved = try await copy.items.update(id, Edit(baseVersion: held.version, tier: .feed))
        #expect(moved.body["properties"] == [:])
        #expect(try #require(try await copy.items.get(id)).tier == .feed)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func theCopyKeepsNumbersAndOrdersKeysAsTheServerDoes(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let id = try await Self.create(copy, ["z": 1, "a": 2, "10": 3, "2": 4, "whole": .number(2.0)])
        let held = try #require(try await copy.items.get(id))
        #expect(held.properties.keys == ["2", "10", "z", "a", "whole"])
        #expect(held.properties["whole"] == .integer(2))
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func twoKeysThatDifferOnlyInNormalizationAreTwoKeys(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        var properties = JSONObject()
        properties[composed] = "composed"
        properties[decomposed] = "decomposed"
        #expect(properties.count == 2)
        let held = try #require(try await copy.items.get(try await Self.create(copy, properties)))
        #expect(held.properties.count == 2)
        #expect(held.properties[composed] == "composed")
        #expect(held.properties[decomposed] == "decomposed")
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEditKeepsEveryPropertyItDoesNotNameIncludingOnesTheTypeDoesNotDeclare(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let id = try await Self.create(copy, ["title": "t", "unknown": ["nested": [1, 2.5, "x"]], "also": nil])
        let version = try #require(try await copy.items.get(id)).version
        _ = try await copy.items.update(id, Edit(properties: ["title": "T"], baseVersion: version))
        let merged = try #require(try await copy.items.get(id))
        #expect(merged.properties == ["title": "T", "unknown": ["nested": [1, 2.5, "x"]], "also": nil])

        _ = try await copy.items.update(
            id, Edit(properties: ["title": "U"], replaceProperties: true, baseVersion: version))
        #expect(try #require(try await copy.items.get(id)).properties == ["title": "U"])
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func anEdgesPropertiesCrossBothWaysAndAnEdgeEditSendsTheValuesItNames(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let reply = try await Self.create(copy, ["title": "reply"])
        let root = try await Self.create(copy, ["title": "root"])
        let made = try await copy.edges.create(
            from: reply, to: root, type: "in-thread", properties: ["position": 1, "note": ["a", nil]])
        let edge = try #require(try await copy.edges.from(reply).first)
        #expect(edge.properties == ["position": 1, "note": ["a", nil]])
        #expect(edge.unreadableProperties == nil)
        _ = try await copy.edges.update(
            try #require(made.edgeId), EdgeEdit(["position": 2], baseVersion: edge.version))
        #expect(try #require(try await copy.edges.to(root).first).properties["position"] == 2)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aDraftOrEditHoldingAValueTheCoreCannotHoldIsRefusedBeforeAnythingIsQueued(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let id = try await Self.create(copy, ["title": "t"])
        let version = try #require(try await copy.items.get(id)).version
        let repeated = JSONObject(members: [
            JSONMember(key: "a", value: .null), JSONMember(key: "a", value: .bool(true)),
        ])
        let nonFinite: JSONObject = ["rating": [1, .number(.infinity)]]
        for bad in [repeated, nonFinite] {
            let attempts: [(String, @Sendable () async throws -> Void)] = [
                ("create", { _ = try await copy.items.create(Draft(type: "app.test.entry", properties: bad)) }),
                ("update", { _ = try await copy.items.update(id, Edit(properties: bad, baseVersion: version)) }),
                ("extension", { _ = try await copy.extensions.write("acme.x", bad, on: id) }),
            ]
            for (_, attempt) in attempts {
                await #expect {
                    try await attempt()
                } throws: { error in
                    if case MarfaError.invalid = error { true } else { false }
                }
            }
        }
        #expect(try await copy.queue.all().count == 1)
        await copy.close()
    }

    /// The server refuses a request body nested more than 64 levels.
    ///
    /// An item's or an edge's properties sit one level down in it, so a value
    /// in a property may nest 62 levels; an extension's body is the object
    /// itself.
    @Test(arguments: CopyKind.allCases)
    func aWriteNestedPastWhatTheServerReadsIsRefusedInvalidAndOneAtTheLimitIsQueued(kind: CopyKind) async throws {
        @Sendable func nested(_ levels: Int) -> JSONObject {
            ["deep": (0..<levels).reduce(JSONValue.null) { inner, _ in .array([inner]) }]
        }
        let copy = try await Self.open(kind)
        let id = try await Self.create(copy, ["title": "t"])
        let other = try await Self.create(copy, ["title": "other"])
        let version = try #require(try await copy.items.get(id)).version
        let made = try await copy.edges.create(from: id, to: other, type: "references", properties: [:])
        let edgeId = try #require(made.edgeId)
        let queued = try await copy.queue.all().count

        func refused(_ levels: Int) async throws {
            let writes: [(String, @Sendable () async throws -> Void)] = [
                (
                    "create",
                    { _ = try await copy.items.create(Draft(type: "app.test.entry", properties: nested(levels))) }
                ),
                (
                    "update",
                    { _ = try await copy.items.update(id, Edit(properties: nested(levels), baseVersion: version)) }
                ),
                (
                    "edge",
                    {
                        _ = try await copy.edges.create(
                            from: id, to: other, type: "references", properties: nested(levels))
                    }
                ),
                ("edge update", { _ = try await copy.edges.update(edgeId, EdgeEdit(nested(levels), baseVersion: 0)) }),
                ("extension", { _ = try await copy.extensions.write("acme.x", nested(levels + 1), on: id) }),
            ]
            for (_, write) in writes {
                await #expect {
                    try await write()
                } throws: { error in
                    if case MarfaError.invalid = error { true } else { false }
                }
            }
        }
        try await refused(63)
        try await refused(200)
        #expect(try await copy.queue.all().count == queued, "a refused write was queued")

        _ = try await copy.items.create(Draft(type: "app.test.entry", properties: nested(62)))
        _ = try await copy.items.create(Draft(type: "app.test.entry", properties: nested(61)))
        _ = try await copy.items.update(id, Edit(properties: nested(62), baseVersion: version))
        _ = try await copy.edges.update(edgeId, EdgeEdit(nested(62), baseVersion: 0))
        _ = try await copy.extensions.write("acme.x", nested(63), on: id)
        #expect(try await copy.queue.all().count == queued + 5)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aWholeNumberMarfaWouldServeBackWithOtherDigitsIsRefusedBeforeAnythingIsQueued(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let id = try await Self.create(copy, ["title": "t"])
        let version = try #require(try await copy.items.get(id)).version
        let queued = try await copy.queue.all().count
        let cases: [(JSONObject, String, String)] = [
            (
                ["beyond": .integer(9_007_199_254_740_993)], "beyond",
                "not 9007199254740993, which it serves as 9007199254740992"
            ),
            (
                ["least": .integer(.min)], "least",
                "not -9223372036854775808, which it serves as -9223372036854776000"
            ),
            (
                ["deep": ["list": [1, ["n": .integer(9_223_372_036_854_775_807)]]]], "deep.list.1.n",
                "not 9223372036854775807, which it serves as 9223372036854776000"
            ),
        ]
        for (bad, path, text) in cases {
            let attempts: [(String, @Sendable () async throws -> Void)] = [
                ("create", { _ = try await copy.items.create(Draft(type: "app.test.entry", properties: bad)) }),
                ("update", { _ = try await copy.items.update(id, Edit(properties: bad, baseVersion: version)) }),
                ("extension", { _ = try await copy.extensions.write("acme.x", bad, on: id) }),
            ]
            for (name, attempt) in attempts {
                await #expect {
                    try await attempt()
                } throws: { error in
                    guard case MarfaError.validation("invalid_properties", let message) = error else {
                        Issue.record("\(name) threw \(error)")
                        return false
                    }
                    return message.contains("\(path): Must be a whole number") && message.contains(text)
                        && message.hasSuffix("Send it as a string.")
                }
            }
        }
        #expect(try await copy.queue.all().count == queued)
        // Witness: whole numbers that are served back as written, at the edge of the rule.
        let kept: JSONObject = [
            "safe": .integer(9_007_199_254_740_991), "sixteen": .integer(9_007_199_254_740_992),
            "exact": .integer(1_152_921_504_606_847_000), "float": .number(9_007_199_254_740_992.0),
        ]
        _ = try await copy.items.update(id, Edit(properties: kept, baseVersion: version))
        _ = try await copy.extensions.write("acme.x", kept, on: id)
        #expect(try await copy.queue.all().count == queued + 2)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aWholeNumberMarfaWouldServeBackWithOtherDigitsIsRefusedOnAnEdge(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let first = try await Self.create(copy, ["title": "first"])
        let second = try await Self.create(copy, ["title": "second"])
        let queued = try await copy.queue.all().count
        await #expect {
            _ = try await copy.edges.create(
                from: first, to: second, type: "in-thread", properties: ["position": .integer(9_007_199_254_740_993)])
        } throws: { error in
            if case MarfaError.validation("invalid_properties", let message) = error {
                message.contains("position: Must be a whole number")
            } else {
                false
            }
        }
        let made = try await copy.edges.create(from: first, to: second, type: "in-thread", properties: ["position": 1])
        await #expect {
            _ = try await copy.edges.update(
                try #require(made.edgeId), EdgeEdit(["position": .integer(9_007_199_254_740_993)], baseVersion: 0))
        } throws: { error in
            if case MarfaError.validation("invalid_properties", _) = error { true } else { false }
        }
        #expect(try await copy.queue.all().count == queued + 1)
        await copy.close()
    }

    /// The core judges a whole number after the refusals that come before it in each
    /// call, so a write that fails one of those is answered with that refusal.
    @Test(arguments: CopyKind.allCases)
    func aWholeNumberMarfaWouldServeBackWithOtherDigitsIsJudgedAfterTheRefusalsThatComeFirst(
        kind: CopyKind
    ) async throws {
        let copy = try await Self.open(kind)
        let first = try await Self.create(copy, ["title": "first"])
        let second = try await Self.create(copy, ["title": "second"])
        let made = try await copy.edges.create(from: first, to: second, type: "in-thread", properties: ["position": 1])
        let edgeId = try #require(made.edgeId)
        let queued = try await copy.queue.all().count
        let beyond: JSONObject = ["position": .integer(9_007_199_254_740_993)]
        let missing = "018f0000-0000-7000-8000-000000000000"

        await #expect {
            _ = try await copy.edges.update(edgeId, EdgeEdit(beyond, baseVersion: 7))
        } throws: { error in
            if case MarfaError.invalid(let message) = error {
                message.contains("is based on version 7 and this copy holds version")
            } else {
                false
            }
        }
        await #expect {
            _ = try await copy.edges.update(missing, EdgeEdit(beyond, baseVersion: 0))
        } throws: { error in
            if case MarfaError.notFound("edge_not_found", _) = error { true } else { false }
        }
        await #expect {
            _ = try await copy.items.create(Draft(type: "app.test.entry", properties: beyond, tags: [""]))
        } throws: { error in
            if case MarfaError.validation("validation_error", let message) = error {
                message.contains("tags[0]: A tag must not be empty")
            } else {
                false
            }
        }
        await #expect {
            _ = try await copy.edges.create(from: first, to: first, type: "in-thread", properties: beyond)
        } throws: { error in
            if case MarfaError.validation("edge_cycle", _) = error { true } else { false }
        }
        // The same write with nothing before it to fail is refused for the number, and
        // where the core judges the number before it looks for the row, so is a write to a
        // row the copy does not hold.
        let unobstructed: [@Sendable () async throws -> Void] = [
            { _ = try await copy.edges.update(edgeId, EdgeEdit(beyond, baseVersion: 0)) },
            { _ = try await copy.items.create(Draft(type: "app.test.entry", properties: beyond, tags: ["t"])) },
            { _ = try await copy.items.update(missing, Edit(properties: beyond, baseVersion: 0)) },
            { _ = try await copy.extensions.write("acme.x", beyond, on: missing) },
            { _ = try await copy.edges.create(from: missing, to: first, type: "in-thread", properties: beyond) },
        ]
        for write in unobstructed {
            await #expect {
                try await write()
            } throws: { error in
                if case MarfaError.validation("invalid_properties", _) = error { true } else { false }
            }
        }
        #expect(try await copy.queue.all().count == queued)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func aValueJSONCannotHoldIsRefusedAsInvalidBeforeAnythingElseIsChecked(kind: CopyKind) async throws {
        let copy = try await kind.open()
        let unwritable: JSONObject = ["r": .number(.nan)]
        let infinite: JSONObject = ["r": .number(-.infinity)]
        let writes: [(String, @Sendable () async throws -> QueuedWrite?)] = [
            ("create", { try await copy.items.create(Draft(type: "core.note", properties: unwritable)) }),
            ("update", { try await copy.items.update("n1", Edit(properties: infinite, baseVersion: 1)) }),
            ("edge", { try await copy.edges.create(from: "a", to: "b", type: "references", properties: unwritable) }),
            ("edge update", { try await copy.edges.update("e1", EdgeEdit(infinite, baseVersion: 1)) }),
            ("extension", { try await copy.extensions.write("ns", unwritable, on: "n1") }),
        ]
        for (name, write) in writes {
            await #expect {
                _ = try await write()
            } throws: { error in
                guard case MarfaError.invalid(let message) = error else {
                    Issue.record("\(name) threw \(error)")
                    return false
                }
                return message.contains("not finite")
            }
        }
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["title": "Writable", "body": ""]))
        #expect(try await copy.queue.all().count == 1)
        await copy.close()
    }

    @Test(arguments: CopyKind.allCases)
    func keysThatDifferOnlyInNormalizationAreChangedOneAtATime(kind: CopyKind) async throws {
        let copy = try await Self.open(kind)
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        var properties = JSONObject()
        properties[composed] = 1
        properties[decomposed] = 2
        let id = try await Self.create(copy, properties)
        var edit = JSONObject()
        edit[decomposed] = 20

        _ = try await copy.items.update(id, Edit(properties: edit, baseVersion: 0))

        let held = try #require(try await copy.items.get(id))
        #expect(held.properties.count == 2 && held.properties[composed] == 1 && held.properties[decomposed] == 20)
        await copy.close()
    }
}
#endif
