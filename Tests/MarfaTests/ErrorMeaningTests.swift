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
        (.notFound(code: "item_not_found", message: "m", server: nil), .none),
        (.unauthorized(code: "unauthorized", message: "m", server: nil), .keyRefusal),
        (.unauthorized(code: "setup_proof_invalid", message: "m", server: nil), .keyRefusal),
        (.forbidden(code: "forbidden", message: "m", server: nil), .none),
        (.forbidden(code: "type_not_permitted", message: "m", server: nil), .none),
        (.forbidden(code: "edge_permission_denied", message: "m", server: nil), .none),
        (.forbidden(code: "core_type_immutable", message: "m", server: nil), .none),
        (.validation(code: "validation_error", message: "m", details: nil, server: nil), .none),
        (.unknownType(message: "m", server: nil), .none),
        (.rateLimited(code: "rate_limited", message: "m", retryAfterSeconds: 3, server: nil), .transient),
        (.rateLimited(code: "rate_limited", message: "m", retryAfterSeconds: nil, server: nil), .transient),
        (.server(status: 500, code: "internal_error", message: "m", details: nil, server: nil), .transient),
        (.server(status: 503, code: "unavailable", message: "m", details: nil, server: nil), .transient),
        (.server(status: 408, code: "request_timeout", message: "m", details: nil, server: nil), .transient),
        (.server(status: 409, code: "conflict", message: "m", details: nil, server: nil), .none),
        (.server(status: 413, code: "payload_too_large", message: "m", details: nil, server: nil), .none),
        (.io(message: "m"), .transient),
        (.network(message: "m"), .offline),
        (.unnamed(status: 502, message: "m", server: nil), .transient),
        (.unnamed(status: 401, message: "m", server: nil), .transient),
        (.decoding(message: "m"), .none),
        (.store(message: "m"), .none),
        (.storeBusy(message: "m"), .transient),
        (.storeDamaged(path: "p", reason: "r", unsent: 1, message: "m"), .none),
        (.storeDamaged(path: "", reason: "r", unsent: nil, message: "m"), .none),
        (.storageFull(message: "m"), .transient),
        (.signedOut(origin: "https://marfa.example", message: "m"), .keyRefusal),
        (.noKeychain(message: "m"), .none),
        (.redirected(origin: "https://marfa.example", status: 302, location: nil, message: "m", server: nil), .none),
        (.noServer(message: "m"), .none),
        (.noCursor(message: "m"), .hydration),
        (.hydrationIncomplete(message: "m"), .hydration),
        (.noCatalog(message: "m"), .none),
        (.wrongSchema(path: "p", reason: "r", unsent: 0, message: "m"), .none),
        (.readingHandle(message: "m"), .none),
        (.unsentDiffers(path: "p", unsent: 1, message: "m"), .none),
        (.copyExpired(reason: "credential_ended", message: "m", server: nil), .keyRefusal),
        (.copyExpired(reason: "reach_changed", message: "m", server: nil), .hydration),
        (.copyExpired(reason: "catchup_too_old", message: "m", server: nil), .hydration),
        (.streamIncomplete(reason: "credential_ended", message: "m", server: nil), .keyRefusal),
        (.streamIncomplete(reason: "replay_failed", message: "m", server: nil), .none),
        (.wrongServer(expected: "a", got: "b", message: "m"), .none),
        (.bytesAbsent(hash: "h", reason: "r", message: "m"), .none),
        (.noRoom(hash: "h", size: 5, free: 3, message: "m"), .none),
        (.contractMismatch(served: "3", expected: 2, status: 200, writeSent: false, message: "m", server: nil), .none),
        (.canceled(message: "m"), .none),
        (.firstSyncWaiting(message: "m"), .hydration),
        (.invalid(message: "m"), .none),
        (.fault(message: "m"), .none),
        (.keyChanging(message: "m"), .transient),
        (.versionConflict(message: "m", server: nil), .none),
        (.instanceChanged(message: "m", server: nil), .hydration),
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
        #expect(throws: Marfa.MarfaError.versionConflict(message: "m", server: nil)) {
            try translated {
                throw MarfaCore.MarfaError.Server(
                    status: 409, code: "version_conflict", message: "m",
                    details: nil, server: nil)
            }
        }
        // Another conflict keeps its status and code.
        #expect(throws: Marfa.MarfaError.server(status: 409, code: "conflict", message: "m", details: nil, server: nil))
        {
            try translated {
                throw MarfaCore.MarfaError.Server(
                    status: 409, code: "conflict", message: "m",
                    details: nil, server: nil)
            }
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
        #expect(throws: Marfa.MarfaError.instanceChanged(message: "m", server: nil)) {
            try translated {
                throw MarfaCore.MarfaError.CopyExpired(
                    reason: "instance_changed", message: "m",
                    server: nil)
            }
        }
        #expect(throws: Marfa.MarfaError.instanceChanged(message: "m", server: nil)) {
            try translated {
                throw MarfaCore.MarfaError.Server(
                    status: 409, code: "instance_changed", message: "m",
                    details: nil, server: nil)
            }
        }
    }

    /// The typed cases keep the word the core and the command line name the error by, and the server's code.
    @Test func theTypedCasesKeepTheCoreNameAndTheServerCode() {
        #expect(Marfa.MarfaError.versionConflict(message: "m", server: nil).code() == "server")
        #expect(Marfa.MarfaError.versionConflict(message: "m", server: nil).fixedText.code == "version_conflict")
        #expect(Marfa.MarfaError.instanceChanged(message: "m", server: nil).code() == "copy_expired")
        #expect(Marfa.MarfaError.instanceChanged(message: "m", server: nil).fixedText.code == "instance_changed")
        #expect(Marfa.MarfaError.keyChanging(message: "m").code() == "key_changing")
        #expect(Marfa.MarfaError.keyChanging(message: "m").fixedText.code == "key_changing")
        for (error, _) in Self.meanings {
            #expect(error.fixedText.type == error.code(), "\(error)")
            #expect(error.message == "m")
        }
    }
}
