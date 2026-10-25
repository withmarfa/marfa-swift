import Foundation
import MarfaCore
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct Values {
    @Test func reportsCarryEveryFieldTheCoreDeclares() {
        func fields(_ value: Any) -> Set<String> {
            Set(Mirror(reflecting: value).children.compactMap(\.label))
        }
        #expect(fields(Marfa.DrainReport()) == fields(Marfa.DrainReport().core))
        #expect(fields(Marfa.Status()) == fields(Marfa.Status().core))
    }

    @Test func jsonRoundTripsThroughItsText() throws {
        let properties: JSONObject = [
            "title": "A note", "count": 3, "ratio": 0.5, "done": false, "none": nil,
            "tags": ["a", "b"], "nested": ["key": "value"],
        ]
        #expect(try JSONObject(json: properties.json()) == properties)
    }

    @Test func anIntegerBeyondWhatADoubleHoldsComesBackExact() throws {
        let read = try JSONObject(json: #"{"id":9007199254740993,"ratio":0.25}"#)
        #expect(read["id"] == .integer(9_007_199_254_740_993))
        #expect(read["ratio"] == .number(0.25))
        #expect(try read.json().contains("9007199254740993"))
    }

    @Test func aNumberReadsAsAnIntegerWhereInt64HoldsItsValue() throws {
        let read = try JSONObject(json: #"{"a":1.0,"b":1e2,"c":9223372036854775808,"d":1.5}"#)
        #expect(read["a"] == .integer(1))
        #expect(read["b"] == .integer(100))
        #expect(read["c"] == .number(9_223_372_036_854_775_808))
        #expect(read["d"] == .number(1.5))
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
    static let cases: [(MarfaCore.MarfaError, Marfa.MarfaError)] = [
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
        (.Unnamed(status: 429, message: "m"), .unnamed(status: 429, message: "m")),
        (.Decoding(message: "m"), .decoding(message: "m")),
        (.Store(message: "m"), .store(message: "m")),
        (.Io(message: "m"), .io(message: "m")),
        (.StorageFull(message: "m"), .storageFull(message: "m")),
        (
            .SignedOut(origin: "https://marfa.example", message: "m"),
            .signedOut(origin: "https://marfa.example", message: "m")
        ),
        (.NoKeychain(message: "m"), .noKeychain(message: "m")),
        (
            .Redirected(origin: "https://marfa.example", status: 307, location: "/next", message: "m"),
            .redirected(origin: "https://marfa.example", status: 307, location: "/next", message: "m")
        ),
        (
            .Redirected(origin: "https://marfa.example", status: 302, location: nil, message: "m"),
            .redirected(origin: "https://marfa.example", status: 302, location: nil, message: "m")
        ),
        (.NoServer(message: "m"), .noServer(message: "m")),
        (.NoCursor(message: "m"), .noCursor(message: "m")),
        (.HydrationIncomplete(message: "m"), .hydrationIncomplete(message: "m")),
        (.NoCatalog(message: "m"), .noCatalog(message: "m")),
        (
            .WrongSchema(path: "p", reason: "shape", unsent: 2, message: "m"),
            .wrongSchema(path: "p", reason: "shape", unsent: 2, message: "m")
        ),
        (.ReadingHandle(message: "m"), .readingHandle(message: "m")),
        (
            .UnsentDiffers(path: "p", unsent: 2, agreed: 1, message: "m"),
            .unsentDiffers(path: "p", unsent: 2, agreed: 1, message: "m")
        ),
        (
            .UnsentDiffers(path: "p", unsent: nil, agreed: 0, message: "m"),
            .unsentDiffers(path: "p", unsent: nil, agreed: 0, message: "m")
        ),
        (.CopyExpired(reason: "aged_out", message: "m"), .copyExpired(reason: "aged_out", message: "m")),
        (
            .CopyExpired(reason: "instance_changed", message: "m"),
            .copyExpired(reason: "instance_changed", message: "m")
        ),
        (.StreamIncomplete(reason: "r", message: "m"), .streamIncomplete(reason: "r", message: "m")),
        (.WrongServer(expected: "a", got: "b", message: "m"), .wrongServer(expected: "a", got: "b", message: "m")),
        (.BytesAbsent(hash: "h", reason: "r", message: "m"), .bytesAbsent(hash: "h", reason: "r", message: "m")),
        (
            .NoRoom(hash: "h", size: 5, free: 3, message: "m"),
            .noRoom(hash: "h", size: 5, free: 3, message: "m")
        ),
        (
            .ContractMismatch(served: "3", expected: 2, status: 201, writeSent: true, message: "m"),
            .contractMismatch(served: "3", expected: 2, status: 201, writeSent: true, message: "m")
        ),
        (
            .ContractMismatch(served: nil, expected: 2, status: 200, writeSent: false, message: "m"),
            .contractMismatch(served: nil, expected: 2, status: 200, writeSent: false, message: "m")
        ),
        (
            .ContractMismatch(served: nil, expected: 2, status: nil, writeSent: false, message: "m"),
            .contractMismatch(served: nil, expected: 2, status: nil, writeSent: false, message: "m")
        ),
        (.Canceled(message: "m"), .canceled(message: "m")),
        (.FirstSyncWaiting(message: "m"), .firstSyncWaiting(message: "m")),
        (.Invalid(message: "m"), .invalid(message: "m")),
    ]

    @Test(arguments: cases)
    func eachCoreErrorArrivesAsItsOwnCase(core: MarfaCore.MarfaError, expected: Marfa.MarfaError) {
        #expect(throws: expected) { try translated { throw core } }
        #expect(expected.code() == core.code())
        #expect(expected.message == "m")
        #expect(expected.localizedDescription == "m")
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
        for kind in Marfa.WriteKind.allCases { #expect(Marfa.WriteKind(kind.core) == kind) }
        for reason in Marfa.BlockedReason.allCases { #expect(Marfa.BlockedReason(reason.core) == reason) }
        for handle in Marfa.Handle.allCases { #expect(Marfa.Handle(handle.core) == handle) }
        for hydration in Marfa.Hydration.allCases { #expect(Marfa.Hydration(hydration.core) == hydration) }
        for field in [Marfa.SortField.createdAt, .updatedAt, .occurredAt, .property(name: "rank")] {
            #expect(Marfa.SortField(field.core) == field)
        }
        for direction in Marfa.SortDirection.allCases { #expect(Marfa.SortDirection(direction.core) == direction) }
        #expect(MarfaCore.EdgeWrittenAt.allCases.map { Marfa.EdgeWrittenAt($0) } == Marfa.EdgeWrittenAt.allCases)
        #expect(Marfa.EdgeWrittenAt(.none) == .none)
        for kind in Marfa.GrantKind.allCases { #expect(Marfa.GrantKind(kind.core) == kind) }
        for level in Marfa.GrantLevel.allCases { #expect(Marfa.GrantLevel(level.core) == level) }
    }

    @Test func everyVerdictCrossesToTheGlueAndBack() {
        let verdicts: [Marfa.Verdict] =
            [
                .accepted, .merged(fields: ["a"]), .conflicted(siblingId: "s", fields: ["a", "b"]),
                .refused(Marfa.Refusal(reason: "r")), .refused(Self.refusal), .dead,
                .blocked(reason: .credentialRefused, refusal: Self.refusal),
            ] + Marfa.BlockedReason.allCases.map { .blocked(reason: $0) }
        for verdict in verdicts { #expect(Marfa.Verdict(verdict.core) == verdict) }
    }

    static let refusal = Marfa.Refusal(
        reason: "validation_error", code: "validation_error", message: "m",
        fields: [Marfa.FieldRefusal(field: "title", message: "too long")], trashed: true,
        grant: Marfa.MissingGrant(kind: .extension, name: "acme", level: .write))

    @Test func aRefusalArrivesInItsParts() {
        let core = MarfaCore.Refusal(
            reason: "validation_error", code: "validation_error", message: "m",
            fields: [MarfaCore.FieldRefusal(field: "title", message: "too long")], trashed: true,
            grant: MarfaCore.MissingGrant(kind: .extension, name: "acme", level: .write))
        #expect(Marfa.Verdict(.refused(refusal: core)) == .refused(Self.refusal))
    }

    @Test func recordsCrossToTheGlueAndBack() {
        let write = Marfa.QueuedWrite(
            id: "q", kind: .uploadBlob, itemId: "i", targetId: "t", edgeId: "e", namespace: "n", tag: "g",
            blob: "b", baseVersion: 2, idempotencyKey: "k", dependsOn: ["d"], follows: "f",
            verdict: .refused(Self.refusal), body: ["title": "kept", "n": 1], answer: ["data": ["id": "i"]],
            refusals: 3, environmentalStreak: 4, lastFailure: Marfa.LastFailure(status: 413, text: "Too Large"),
            queuedAt: "t0", answeredAt: "t1")
        #expect(Marfa.QueuedWrite(write.core) == write)
        #expect(write.core.environmentalStreak == 4)
        #expect(write.core.lastFailure == MarfaCore.LastFailure(status: 413, text: "Too Large"))
        for failure in [Marfa.LastFailure(status: nil), Marfa.LastFailure(status: 503, text: nil)] {
            #expect(Marfa.LastFailure(failure.core) == failure)
        }
        let waiting = Marfa.QueuedWrite(id: "w", kind: .updateItem, idempotencyKey: "k", waiting: true, queuedAt: "t0")
        #expect(Marfa.QueuedWrite(waiting.core) == waiting)
        let report = Marfa.DrainReport(
            answered: 1, held: 2, undelivered: 3, unsent: 4, unmade: 5, unavailable: "network",
            verdicts: [
                Marfa.DrainVerdict(
                    id: "q", kind: .addTag, itemId: "i", edgeId: "e", verdict: .dead, refusals: 1, replayed: true)
            ],
            stopped: "s", unclaimedSources: ["u"], retryAfterSeconds: 4)
        #expect(Marfa.DrainReport(report.core) == report)
        let hydrated = Marfa.HydrateReport(
            types: ["t"], tier: .feed, edgeTypes: ["e"], items: 1, edges: 2, pages: 3, pagesTotal: 5,
            resumed: true, restarted: "slice_changed", inPlace: true, cursor: "c", registeredTypes: ["app.new"],
            unregisteredTypes: [Marfa.UnregisteredType(id: "app.no", code: "forbidden", message: "m")],
            replacedTypes: ["app.changed"],
            unreplacedTypes: [Marfa.UnregisteredType(id: "app.held", code: "conflict", message: "n")])
        #expect(Marfa.HydrateReport(hydrated.core) == hydrated)
        #expect(Marfa.HydrateReport(hydrated.core).inPlace && hydrated.core.inPlace)
        #expect(
            !Marfa.HydrateReport(types: [], tier: .all, edgeTypes: [], items: 0, edges: 0, pages: 0, cursor: "").inPlace
        )
        let caught = Marfa.CatchUpReport(applied: 1, skipped: 2, cursor: "c", catalogChanged: true)
        #expect(Marfa.CatchUpReport(caught.core) == caught)
        let status = Marfa.Status(
            serverOrigin: "o", sliceTypes: ["t"], sliceTier: .library, sliceEdgeTypes: ["e"], pinned: ["p"],
            eventCursor: "c", hydration: .inProgress, items: 1, itemsExpected: 10, itemsListed: 4, edges: 2,
            catalogVersion: 5,
            instanceId: "instance",
            fileCache: FileCache(
                setting: .bytes(bytes: 5), budget: 5, held: 3, heldUnreadable: nil, volumeUnreadable: true,
                backupMarkFailure: "no",
                attachments: Attachments(
                    held: 1, heldBytes: 2, partialBytes: 3, notHeld: 4, notHeldBytes: 5,
                    notHeldByReason: [NotHeld(reason: .rateLimited, attachments: 4, bytes: 5, unstated: 1)])))
        #expect(Marfa.Status(status.core) == status)
        let unheld = Marfa.Status(hydration: .never)
        #expect(Marfa.Status(unheld.core).catalogVersion == nil)
        let sort = Marfa.Sort(field: .occurredAt, direction: .descending)
        #expect(Marfa.Sort(sort.core) == sort)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CatalogTypes {
    static func field(_ name: String, declaredBy: String, definition: JSONObject) -> MarfaCore.TypeField {
        MarfaCore.TypeField(
            name: name, fieldType: "string", required: true, description: "d", declaredBy: declaredBy,
            definition: definition)
    }

    @Test func anItemTypeArrivesWithEachFieldAndWhereItIsDeclared() {
        let core = MarfaCore.ItemType(
            id: "user.recipe", label: "Recipe", description: "A dish", parent: "user.dish", version: 3,
            fields: [
                Self.field(
                    "serves", declaredBy: "user.dish", definition: ["type": "string", "required": true, "x": [1, 2]]),
                Self.field("title", declaredBy: "user.recipe", definition: ["type": "string"]),
            ],
            titleField: "title", bodyField: "method", linkField: "vendor_id", roles: ["container"],
            compatibleWith: ["user.meal"])
        let type = Marfa.ItemType(core)
        #expect(
            type
                == Marfa.ItemType(
                    id: "user.recipe", label: "Recipe", description: "A dish", parent: "user.dish", version: 3,
                    fields: [
                        Marfa.TypeField(
                            name: "serves", type: "string", required: true, description: "d",
                            declaredBy: "user.dish", definition: ["type": "string", "required": true, "x": [1, 2]]),
                        Marfa.TypeField(
                            name: "title", type: "string", required: true, description: "d",
                            declaredBy: "user.recipe", definition: ["type": "string"]),
                    ],
                    titleField: "title", bodyField: "method", linkField: "vendor_id", roles: ["container"],
                    compatibleWith: ["user.meal"]))
    }

    @Test func anEdgeTypeArrivesWithItsReverseNameAndTheEndThatWritesIt() {
        let core = MarfaCore.EdgeType(
            id: "mentor-of", label: "Mentor of", reverseLabel: "Mentored by", description: nil,
            cardinality: "one-to-many",
            reverseName: "mentored-by", writtenAt: .target, sourceTypeConstraints: ["core.person"],
            targetTypeConstraints: ["*"], cascadeOnDelete: "block",
            properties: [Self.field("since", declaredBy: "mentor-of", definition: ["type": "string"])],
            shipped: false)
        let type = Marfa.EdgeType(core)
        #expect(
            type
                == Marfa.EdgeType(
                    id: "mentor-of", label: "Mentor of", reverseLabel: "Mentored by", cardinality: "one-to-many",
                    reverseName: "mentored-by",
                    writtenAt: .target, sourceTypeConstraints: ["core.person"], targetTypeConstraints: ["*"],
                    cascadeOnDelete: "block",
                    properties: [
                        Marfa.TypeField(
                            name: "since", type: "string", required: true, description: "d",
                            declaredBy: "mentor-of", definition: ["type": "string"])
                    ]))
    }

    @Test func anEdgeTypeWithNoReverseLabelNamesBothEndsByItsLabel() {
        let type = Marfa.EdgeType(id: "related-to", label: "Related to", cardinality: "many-to-many")
        #expect(type.reverseLabel == "Related to")
        let one = Marfa.EdgeType(id: "parent-of", label: "Children", reverseLabel: "Parent", cardinality: "one-to-many")
        #expect(one.reverseLabel == "Parent", "the witness: a registered reverse label stays")
    }

    @Test func aFreshCopyReadsTheBuiltInCatalogWithoutHydration() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        #expect(try await copy.status().catalogVersion == nil)
        #expect(try await copy.catalog.itemTypes().contains { $0.id == "core.note" })
        #expect(try await copy.catalog.itemType("core.note").id == "core.note")
        #expect(try await copy.catalog.edgeTypes().contains { $0.id == "references" })
        #expect(try await copy.catalog.edgeType("references").id == "references")
        await copy.close()
    }
}
