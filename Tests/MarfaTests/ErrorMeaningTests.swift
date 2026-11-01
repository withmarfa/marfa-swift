import Foundation
import MarfaCore
import Testing

@testable import Marfa

/// What an error means for an app: offline, a refused key, a failure that passes by itself, or a copy that needs a
/// hydration.
@Suite struct ErrorMeaning {
    private struct Meaning: Equatable, CustomStringConvertible {
        var offline = false
        var keyRefusal = false
        var transient = false
        var hydrationNeeded = false

        static let none = Meaning()
        static let offline = Meaning(offline: true, transient: true)
        static let keyRefusal = Meaning(keyRefusal: true)
        static let transient = Meaning(transient: true)
        static let hydration = Meaning(hydrationNeeded: true)

        var description: String {
            "offline \(offline), key refusal \(keyRefusal), transient \(transient), hydration needed \(hydrationNeeded)"
        }
    }

    /// One example of every case, and some of them more than once where the values they carry change the answer.
    private static let meanings: [(Marfa.MarfaError, Meaning)] = [
        (.notFound(code: "item_not_found", message: "m"), .none),
        (.unauthorized(code: "unauthorized", message: "m"), .keyRefusal),
        (.unauthorized(code: "setup_proof_invalid", message: "m"), .keyRefusal),
        (.forbidden(code: "forbidden", message: "m"), .none),
        (.forbidden(code: "type_not_permitted", message: "m"), .none),
        (.forbidden(code: "edge_permission_denied", message: "m"), .none),
        (.forbidden(code: "core_type_immutable", message: "m"), .none),
        (.validation(code: "validation_error", message: "m"), .none),
        (.unknownType(message: "m"), .none),
        (.rateLimited(code: "rate_limited", message: "m", retryAfterSeconds: 3), .transient),
        (.rateLimited(code: "rate_limited", message: "m", retryAfterSeconds: nil), .transient),
        (.server(status: 500, code: "internal_error", message: "m"), .transient),
        (.server(status: 503, code: "unavailable", message: "m"), .transient),
        (.server(status: 408, code: "request_timeout", message: "m"), .transient),
        (.server(status: 409, code: "conflict", message: "m"), .none),
        (.server(status: 413, code: "payload_too_large", message: "m"), .none),
        (.io(message: "m"), .transient),
        (.network(message: "m"), .offline),
        (.unnamed(status: 502, message: "m"), .transient),
        (.unnamed(status: 401, message: "m"), .transient),
        (.decoding(message: "m"), .none),
        (.store(message: "m"), .none),
        (.storageFull(message: "m"), .transient),
        (.signedOut(origin: "https://marfa.example", message: "m"), .keyRefusal),
        (.noKeychain(message: "m"), .none),
        (.redirected(origin: "https://marfa.example", status: 302, location: nil, message: "m"), .none),
        (.noServer(message: "m"), .none),
        (.noCursor(message: "m"), .hydration),
        (.hydrationIncomplete(message: "m"), .hydration),
        (.noCatalog(message: "m"), .none),
        (.wrongSchema(path: "p", reason: "r", unsent: 0, message: "m"), .none),
        (.readingHandle(message: "m"), .none),
        (.unsentDiffers(path: "p", unsent: 1, agreed: 0, message: "m"), .none),
        (.copyExpired(reason: "credential_ended", message: "m"), .keyRefusal),
        (.copyExpired(reason: "reach_changed", message: "m"), .hydration),
        (.copyExpired(reason: "catchup_too_old", message: "m"), .hydration),
        (.streamIncomplete(reason: "credential_ended", message: "m"), .keyRefusal),
        (.streamIncomplete(reason: "replay_failed", message: "m"), .none),
        (.wrongServer(expected: "a", got: "b", message: "m"), .none),
        (.bytesAbsent(hash: "h", reason: "r", message: "m"), .none),
        (.noRoom(hash: "h", size: 5, free: 3, message: "m"), .none),
        (.contractMismatch(served: "3", expected: 2, status: 200, writeSent: false, message: "m"), .none),
        (.canceled(message: "m"), .none),
        (.firstSyncWaiting(message: "m"), .hydration),
        (.invalid(message: "m"), .none),
        (.fault(message: "m"), .none),
        (.keyChanging(message: "m"), .transient),
        (.versionConflict(message: "m"), .none),
        (.instanceChanged(message: "m"), .hydration),
        (.closed(message: "m"), .none),
        (.noConnection(message: "m"), .offline),
    ]

    @Test(arguments: meanings)
    private func eachErrorSaysWhatItMeans(error: Marfa.MarfaError, meaning: Meaning) {
        let said = Meaning(
            offline: error.isOffline, keyRefusal: error.isKeyRefusal, transient: error.isTransient,
            hydrationNeeded: error.isHydrationNeeded)
        #expect(said == meaning, "\(error)")
    }

    @Test func noErrorIsBothARefusedKeyAndOneThatPassesByItself() {
        for (error, _) in Self.meanings {
            #expect(!(error.isKeyRefusal && error.isTransient), "\(error)")
            #expect(!error.isOffline || error.isTransient, "\(error)")
            #expect(!(error.isHydrationNeeded && (error.isKeyRefusal || error.isTransient)), "\(error)")
        }
    }

    @Test func aConflictingVersionArrivesAsItsOwnCase() {
        #expect(throws: Marfa.MarfaError.versionConflict(message: "m")) {
            try translated { throw MarfaCore.MarfaError.Server(status: 409, code: "version_conflict", message: "m") }
        }
        // Another conflict keeps its status and code.
        #expect(throws: Marfa.MarfaError.server(status: 409, code: "conflict", message: "m")) {
            try translated { throw MarfaCore.MarfaError.Server(status: 409, code: "conflict", message: "m") }
        }
    }

    @Test func aFaultInTheCoreArrivesAsItsOwnCase() {
        #expect(throws: Marfa.MarfaError.fault(message: "m")) {
            try translated { throw MarfaCore.MarfaError.Fault(message: "m") }
        }
        #expect(Marfa.MarfaError.fault(message: "m").code() == "fault")
        #expect(Marfa.MarfaError.fault(message: "m").fixedText.code == "fault")
    }

    @Test func anotherInstanceAtTheAddressArrivesAsItsOwnCase() {
        #expect(throws: Marfa.MarfaError.instanceChanged(message: "m")) {
            try translated { throw MarfaCore.MarfaError.CopyExpired(reason: "instance_changed", message: "m") }
        }
        #expect(throws: Marfa.MarfaError.instanceChanged(message: "m")) {
            try translated { throw MarfaCore.MarfaError.Server(status: 409, code: "instance_changed", message: "m") }
        }
    }

    /// The typed cases keep the word the core and the command line name the error by, and the server's code.
    @Test func theTypedCasesKeepTheCoreNameAndTheServerCode() {
        #expect(Marfa.MarfaError.versionConflict(message: "m").code() == "server")
        #expect(Marfa.MarfaError.versionConflict(message: "m").fixedText.code == "version_conflict")
        #expect(Marfa.MarfaError.instanceChanged(message: "m").code() == "copy_expired")
        #expect(Marfa.MarfaError.instanceChanged(message: "m").fixedText.code == "instance_changed")
        #expect(Marfa.MarfaError.keyChanging(message: "m").code() == "key_changing")
        #expect(Marfa.MarfaError.keyChanging(message: "m").fixedText.code == "key_changing")
        for (error, _) in Self.meanings {
            #expect(error.fixedText.type == error.code(), "\(error)")
            #expect(error.message == "m")
        }
    }
}
