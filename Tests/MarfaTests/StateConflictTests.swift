import MarfaCore
import Testing

@testable import Marfa

@Suite struct StateConflict {
    @Test func aServerConflictPreservesItsMessageAndStatesThroughBothTransports() async throws {
        let message = "The item is trashed."
        let details: Marfa.JSONValue = ["expected": "archived", "actual": "trashed"]
        let answer = Marfa.ServerAnswer(status: 409, code: "state_conflict", details: details, requestId: "request")
        let expected = Marfa.MarfaError.validation(
            code: "state_conflict", message: message, details: details, server: answer)
        let core = MarfaCore.MarfaError.Server(
            status: 409, code: "state_conflict", message: message, details: details.core, server: answer.core)
        #expect(Marfa.MarfaError(core) == expected)
        let direct = await refusal(
            status: 409, contract: String(marfaContractVersion), location: nil, retryAfter: nil,
            requestId: "request", origin: "https://marfa.example", write: true
        ) {
            #"{"error":{"code":"state_conflict","message":"The item is trashed.","details":{"expected":"archived","actual":"trashed"}}}"#
        }
        #expect(direct == expected)
        #expect(direct?.errorDescription == message)
    }
}
