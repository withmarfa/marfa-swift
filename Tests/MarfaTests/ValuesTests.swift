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
