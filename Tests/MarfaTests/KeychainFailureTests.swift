import Foundation
import Security
import Testing

@testable import Marfa

@Suite struct KeychainFailureMessages {
    @Test(arguments: [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed])
    func aKnownStatusReadsAsTheSecurityFrameworkSaysIt(status: OSStatus) throws {
        let said = try #require(SecCopyErrorMessageString(status, nil) as String?)
        let failure = Keychain.Failure(status: status)
        #expect(failure.status == status)
        #expect(failure.errorDescription == said)
        #expect(failure.localizedDescription == said)
        #expect(failure.description == said)
        #expect("\(failure)" == said)
    }

    @Test func anUnknownStatusNamesItsNumber() {
        let failure = Keychain.Failure(status: -1_234_567)
        #expect(failure.description.contains("-1234567"))
        #expect(failure.localizedDescription == failure.description)
    }
}
