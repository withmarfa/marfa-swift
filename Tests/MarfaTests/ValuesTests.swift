import Foundation
import MarfaCoreNames
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct Values {
    @Test func jsonRoundTripsThroughTheTextTheCoreTakes() throws {
        let properties: [String: JSONValue] = [
            "title": "A note", "count": 3, "ratio": 0.5, "done": false, "none": nil,
            "tags": ["a", "b"], "nested": ["key": "value"],
        ]
        #expect(try Properties.object(Properties.text(properties)) == properties)
    }

    @Test func anIntegerBeyondWhatADoubleHoldsComesBackExact() throws {
        let read = try Properties.object(#"{"id":9007199254740993,"ratio":0.25}"#)
        #expect(read["id"] == .integer(9_007_199_254_740_993))
        #expect(read["ratio"] == .number(0.25))
        #expect(try Properties.text(read).contains("9007199254740993"))
    }

    @Test func aNumberReadsAsAnIntegerWhereInt64HoldsItsValue() throws {
        let read = try Properties.object(#"{"a":1.0,"b":1e2,"c":9223372036854775808,"d":1.5}"#)
        #expect(read["a"] == .integer(1))
        #expect(read["b"] == .integer(100))
        #expect(read["c"] == .number(9_223_372_036_854_775_808))
        #expect(read["d"] == .number(1.5))
    }

    @Test func propertiesTheCoreCannotReadAreRefusedRatherThanEmptied() {
        let unreadable = CoreItem(
            id: "n1", type: "core.note", propertiesJson: "[1,2]", state: .active, tier: nil, version: 1,
            schemaVersion: 1, source: "device", sourceId: nil, occurredAt: "", createdAt: "", updatedAt: "",
            tags: [])
        #expect {
            try translated { try Item(unreadable) }
        } throws: { error in
            if case Marfa.MarfaError.decoding = error { true } else { false }
        }
    }

    @Test func aServerNeverShowsItsKey() {
        let server = Server(url: URL(string: "https://marfa.example")!, key: "mk_secret")
        var dumped = ""
        dump(server, to: &dumped)
        let shown = ["\(server)", String(reflecting: server), dumped]
        for text in shown {
            #expect(!text.contains("mk_secret"), "\(text)")
            #expect(text.contains("marfa.example"), "\(text)")
        }
        #expect(Mirror(reflecting: server).children.map(\.label) == ["url"])
    }
}

@Suite(.timeLimit(.minutes(1)))
struct Errors {
    static let cases: [(CoreMarfaError, Marfa.MarfaError)] = [
        (.NotFound(code: "c", message: "m"), .notFound(code: "c", message: "m")),
        (.Unauthorized(code: "c", message: "m"), .unauthorized(code: "c", message: "m")),
        (.Forbidden(code: "c", message: "m"), .forbidden(code: "c", message: "m")),
        (.Validation(code: "c", message: "m"), .validation(code: "c", message: "m")),
        (.UnknownType(message: "m"), .unknownType(message: "m")),
        (
            .RateLimited(code: "c", message: "m", retryAfterSeconds: 9),
            .rateLimited(code: "c", message: "m", retryAfterSeconds: 9)
        ),
        (.Server(status: 503, code: "c", message: "m"), .server(status: 503, code: "c", message: "m")),
        (.Network(message: "m"), .network(message: "m")),
        (.Decoding(message: "m"), .decoding(message: "m")),
        (.Store(message: "m"), .store(message: "m")),
        (.NoServer(message: "m"), .noServer(message: "m")),
        (.NoCursor(message: "m"), .noCursor(message: "m")),
        (.HydrationIncomplete(message: "m"), .hydrationIncomplete(message: "m")),
        (.NoCatalog(message: "m"), .noCatalog(message: "m")),
        (
            .WrongSchema(expected: "8", found: "7", path: "p", message: "m"),
            .wrongSchema(expected: "8", found: "7", path: "p", message: "m")
        ),
        (.ReadingHandle(message: "m"), .readingHandle(message: "m")),
        (.CatchUpTooOld(minRetainedId: "5", message: "m"), .catchUpTooOld(minRetainedId: "5", message: "m")),
        (.StreamIncomplete(reason: "r", message: "m"), .streamIncomplete(reason: "r", message: "m")),
        (.WrongServer(expected: "a", got: "b", message: "m"), .wrongServer(expected: "a", got: "b", message: "m")),
        (.BytesAbsent(hash: "h", reason: "r", message: "m"), .bytesAbsent(hash: "h", reason: "r", message: "m")),
        (
            .ContractMismatch(served: "3", expected: 2, status: 201, writeSent: true, message: "m"),
            .contractMismatch(served: "3", expected: 2, status: 201, writeSent: true, message: "m")
        ),
        (
            .ContractMismatch(served: nil, expected: 2, status: 200, writeSent: false, message: "m"),
            .contractMismatch(served: nil, expected: 2, status: 200, writeSent: false, message: "m")
        ),
        (.Invalid(message: "m"), .invalid(message: "m")),
    ]

    @Test(arguments: cases)
    func eachCoreErrorArrivesAsItsOwnCase(core: CoreMarfaError, expected: Marfa.MarfaError) {
        #expect(throws: expected) { try translated { throw core } }
        #expect(expected.message == "m")
        #expect(expected.localizedDescription == "m")
    }

    /// The copy was never hydrated, so `invalid` rather than
    /// `hydrationIncomplete` shows the package refused the value first.
    @Test func aValueJSONCannotHoldIsRefusedAsInvalid() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let unwritable: [String: JSONValue] = ["r": .number(.nan)]
        let infinite: [String: JSONValue] = ["r": .number(-.infinity)]
        let writes: [(String, @Sendable () async throws -> QueuedWrite)] = [
            ("create", { try await copy.items.create(Draft(type: "core.note", properties: unwritable)) }),
            ("update", { try await copy.items.update("n1", Edit(properties: infinite, baseVersion: 1)) }),
            ("edge", { try await copy.edges.create(from: "a", to: "b", type: "references", properties: unwritable) }),
            ("edge update", { try await copy.edges.update("e1", properties: infinite, baseVersion: 1) }),
            ("extension", { try await copy.extensions.write("ns", unwritable, on: "n1") }),
        ]
        for (name, write) in writes {
            await #expect {
                _ = try await write()
            } throws: { error in
                guard case Marfa.MarfaError.invalid(let message) = error else {
                    Issue.record("\(name) threw \(error)")
                    return false
                }
                return message.contains("r cannot be written as JSON")
            }
        }
        await #expect {
            _ = try await copy.items.create(Draft(type: "core.note", properties: ["r": .number(1)]))
        } throws: { error in
            if case Marfa.MarfaError.hydrationIncomplete = error { true } else { false }
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct Opening {
    @Test func aReadingOpenRefusesAPathWithNoStoreAndMakesNone() async throws {
        let path = temporaryStore()
        await #expect {
            _ = try await WorkingCopy.openReader(store: path)
        } throws: { error in
            if case Marfa.MarfaError.invalid = error { true } else { false }
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let writer = try await WorkingCopy.open(store: path)
        #expect(writer.handle == .writer)
        let reader = try await WorkingCopy.openReader(store: path)
        #expect(reader.handle == .reader)
    }

}

@Suite(.timeLimit(.minutes(1)))
struct OwnValueTypes {
    @Test func everyEnumCaseCrossesToTheGlueAndBack() {
        for tier in Tier.allCases { #expect(Tier(tier.core) == tier) }
        for state in ItemState.allCases { #expect(ItemState(state.core) == state) }
        for kind in WriteKind.allCases { #expect(WriteKind(kind.core) == kind) }
        for reason in BlockedReason.allCases { #expect(BlockedReason(reason.core) == reason) }
        for handle in Handle.allCases { #expect(Handle(handle.core) == handle) }
        for hydration in Hydration.allCases { #expect(Hydration(hydration.core) == hydration) }
        for field in SortField.allCases { #expect(SortField(field.core) == field) }
        for direction in SortDirection.allCases { #expect(SortDirection(direction.core) == direction) }
        for end in EdgeEnd.allCases { #expect(EdgeEnd(end.core) == end) }
        for kind in GrantKind.allCases { #expect(GrantKind(kind.core) == kind) }
        for level in GrantLevel.allCases { #expect(GrantLevel(level.core) == level) }
    }

    @Test func everyVerdictCrossesToTheGlueAndBack() {
        let verdicts: [Verdict] =
            [
                .accepted, .merged(fields: ["a"]), .conflicted(siblingId: "s", fields: ["a", "b"]),
                .refused(Refusal(reason: "r")), .refused(Self.refusal), .dead,
            ] + BlockedReason.allCases.map { .blocked(reason: $0) }
        for verdict in verdicts { #expect(Verdict(verdict.core) == verdict) }
    }

    static let refusal = Refusal(
        reason: "validation_error", code: "validation_error", message: "m",
        fields: [FieldRefusal(field: "title", message: "too long")], trashed: true,
        grant: MissingGrant(kind: .extension, name: "acme", level: .write))

    @Test func aRefusalArrivesInItsParts() {
        let core = CoreRefusal(
            reason: "validation_error", code: "validation_error", message: "m",
            fields: [CoreFieldRefusal(field: "title", message: "too long")], trashed: true,
            grant: CoreMissingGrant(kind: .extension, name: "acme", level: .write))
        #expect(Verdict(.refused(refusal: core)) == .refused(Self.refusal))
    }

    @Test func recordsCrossToTheGlueAndBack() throws {
        let write = QueuedWrite(
            id: "q", kind: .uploadBlob, itemId: "i", targetId: "t", edgeId: "e", namespace: "n", tag: "g",
            blob: "b", baseVersion: 2, idempotencyKey: "k", dependsOn: ["d"], follows: "f",
            verdict: .refused(Self.refusal), body: ["title": "kept", "n": 1], answer: "a", refusals: 3,
            queuedAt: "t0", answeredAt: "t1")
        #expect(try QueuedWrite(write.core()) == write)
        let waiting = QueuedWrite(id: "w", kind: .updateItem, idempotencyKey: "k", waiting: true, queuedAt: "t0")
        #expect(try QueuedWrite(waiting.core()) == waiting)
        let report = DrainReport(
            sent: 1, held: 2,
            verdicts: [
                DrainVerdict(
                    id: "q", kind: .addTag, itemId: "i", edgeId: "e", verdict: .dead, refusals: 1, replayed: true)
            ],
            stopped: "s", unclaimedSources: ["u"], retryAfterSeconds: 4)
        #expect(DrainReport(report.core) == report)
        let hydrated = HydrateReport(
            types: ["t"], tier: .feed, edgeTypes: ["e"], items: 1, edges: 2, pages: 3, cursor: "c")
        #expect(HydrateReport(hydrated.core) == hydrated)
        let caught = CatchUpReport(applied: 1, skipped: 2, cursor: "c", reachedHead: false)
        #expect(CatchUpReport(caught.core) == caught)
        let status = Status(
            serverOrigin: "o", sliceTypes: ["t"], sliceTier: .library, sliceEdgeTypes: ["e"], pinned: ["p"],
            eventCursor: "c", hydration: .inProgress, items: 1, edges: 2, catalogVersion: 5)
        #expect(Status(status.core) == status)
        let unheld = Status(hydration: .never)
        #expect(Status(unheld.core).catalogVersion == nil)
        let sort = Sort(field: .occurredAt, direction: .descending)
        #expect(Sort(sort.core) == sort)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct QueuedBodies {
    @Test func aBodyTheCoreCannotReadIsRefusedRatherThanEmptied() throws {
        var core = try QueuedWrite(id: "q", kind: .createItem, idempotencyKey: "k", queuedAt: "t0").core()
        core.bodyJson = "[1]"
        #expect {
            try translated { try QueuedWrite(core) }
        } throws: { error in
            if case Marfa.MarfaError.decoding = error { true } else { false }
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CatalogTypes {
    static func field(_ name: String, declaredBy: String, json: String) -> CoreTypeField {
        CoreTypeField(
            name: name, fieldType: "string", required: true, description: "d", declaredBy: declaredBy,
            definitionJson: json)
    }

    @Test func anItemTypeArrivesWithEachFieldAndWhereItIsDeclared() throws {
        let core = CoreItemType(
            id: "user.recipe", label: "Recipe", description: "A dish", parent: "user.dish", version: 3,
            fields: [
                Self.field("serves", declaredBy: "user.dish", json: #"{"type":"string","required":true,"x":[1,2]}"#),
                Self.field("title", declaredBy: "user.recipe", json: #"{"type":"string"}"#),
            ],
            titleField: "title", bodyField: "method", linkField: "vendor_id", roles: ["container"],
            compatibleWith: ["user.meal"])
        let type = try ItemType(core)
        #expect(
            type
                == ItemType(
                    id: "user.recipe", label: "Recipe", description: "A dish", parent: "user.dish", version: 3,
                    fields: [
                        TypeField(
                            name: "serves", type: "string", required: true, description: "d",
                            declaredBy: "user.dish", definition: ["type": "string", "required": true, "x": [1, 2]]),
                        TypeField(
                            name: "title", type: "string", required: true, description: "d",
                            declaredBy: "user.recipe", definition: ["type": "string"]),
                    ],
                    titleField: "title", bodyField: "method", linkField: "vendor_id", roles: ["container"],
                    compatibleWith: ["user.meal"]))
    }

    @Test func anEdgeTypeArrivesWithItsReverseNameAndTheEndThatWritesIt() throws {
        let core = CoreEdgeType(
            id: "mentor-of", label: "Mentor of", description: nil, cardinality: "one-to-many",
            reverseName: "mentored-by", writtenAt: .target, sourceTypeConstraints: ["core.person"],
            targetTypeConstraints: ["*"], cascadeOnDelete: "block",
            properties: [Self.field("since", declaredBy: "mentor-of", json: #"{"type":"string"}"#)], shipped: false)
        let type = try EdgeType(core)
        #expect(
            type
                == EdgeType(
                    id: "mentor-of", label: "Mentor of", cardinality: "one-to-many", reverseName: "mentored-by",
                    writtenAt: .target, sourceTypeConstraints: ["core.person"], targetTypeConstraints: ["*"],
                    cascadeOnDelete: "block",
                    properties: [
                        TypeField(
                            name: "since", type: "string", required: true, description: "d",
                            declaredBy: "mentor-of", definition: ["type": "string"])
                    ]))
    }

    @Test func aDefinitionThatIsNoObjectIsRefusedRatherThanEmptied() {
        let core = CoreItemType(
            id: "t", label: nil, description: nil, parent: nil, version: 0,
            fields: [Self.field("f", declaredBy: "t", json: "[1]")], titleField: nil, bodyField: nil,
            linkField: nil, roles: [], compatibleWith: [])
        #expect {
            try translated { try ItemType(core) }
        } throws: { error in
            if case Marfa.MarfaError.decoding = error { true } else { false }
        }
    }

    /// An empty list would read as an instance with no types at all.
    @Test func aCopyThatNeverHeldACatalogSaysSoForEveryRead() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        #expect(try await copy.status().catalogVersion == nil)
        let reads: [(String, @Sendable () async throws -> Void)] = [
            ("item types", { _ = try await copy.catalog.itemTypes() }),
            ("item type", { _ = try await copy.catalog.itemType("core.note") }),
            ("edge types", { _ = try await copy.catalog.edgeTypes() }),
            ("edge type", { _ = try await copy.catalog.edgeType("references") }),
        ]
        for (name, read) in reads {
            await #expect {
                try await read()
            } throws: { error in
                guard case Marfa.MarfaError.noCatalog = error else {
                    Issue.record("\(name) threw \(error)")
                    return false
                }
                return true
            }
        }
    }
}
