import Foundation
import Marfa
import MarfaTypes

/// A change to the addresses people reach the instance at.
///
/// Moving the sign-in address ends every browser sign-in, makes every passkey unusable until the owner adds one at
/// the new address, and signs every app out, so the server asks for the owner's confirmation. Make the change in
/// three steps:
///
/// 1. ``Client/check(_:)`` says what the change would do, writes nothing, and says whether the new address answers
///    as this instance.
/// 2. Show the owner `consequences` and, once they agree, ``Client/apply(_:after:expecting:)``. It confirms the
///    move for the owner when the server asks for that, and the server wants them to have signed in within the last
///    five minutes: a ``Server`` set up with ``Server/confirming(from:prefersEphemeralWebBrowserSession:)`` signs
///    them in again by itself, and a key is refused with ``MarfaError/appSignInRequired(message:server:)``.
/// 3. Take the owner through `nextSteps` in order: sign in at the new address, then add a passkey there.
public struct AddressChange: Sendable, Hashable {
    /// Where people sign in, an origin with no path; ``SettingChange/clear`` makes it this computer's own address.
    public var signInAddress: SettingChange<String>?
    /// Every address people reach the instance at, each an origin with no path.
    ///
    /// The sign-in address is always one of them. ``SettingChange/clear`` removes them, so the server's default
    /// applies.
    public var addresses: SettingChange<[String]>?

    /// A field left `nil` is not sent, so the server keeps it as it is.
    public init(signInAddress: SettingChange<String>? = nil, addresses: SettingChange<[String]>? = nil) {
        self.signInAddress = signInAddress
        self.addresses = addresses
    }
}

extension Client {
    /// What `change` would do, and whether its new sign-in address answers as this instance.
    ///
    /// Writes nothing.
    ///
    /// Needs `config.manage`. The answer's `requiresConfirmation` says whether a write needs the owner's agreement,
    /// and `signInAddressCheck.passed` is `false` when the new address does not answer as this instance, with its
    /// `reason`; a write of such a change is refused with the code `sign_in_address_check_failed`.
    public func check(_ change: AddressChange) async throws(MarfaError) -> Components.Schemas.AddressCheck {
        let body = Components.Schemas.AddressCheckRequest(
            signInAddress: change.signInAddress.map(Self.nullable), addresses: change.addresses.map(Self.nullable))
        return try await answer("checkAddressChange") { try await checkAddressChange(body: .json(body)).ok.body.json }
    }

    /// Makes `change`, confirming a move of the sign-in address as `check` says the server asks, and answers the
    /// settings as stored.
    ///
    /// `check` is what ``check(_:)`` answered for `change`, so a move the owner has not been shown is not
    /// confirmed for them. `instanceID` makes the server refuse the change with
    /// ``MarfaError/instanceChanged(message:server:)`` when another instance now answers at this address.
    public func apply(
        _ change: AddressChange, after check: Components.Schemas.AddressCheck, expecting instanceID: String? = nil
    ) async throws(MarfaError) -> Components.Schemas.InstanceConfig {
        let body = Operations.UpdateConfig.Input.Body.JsonPayload(
            addresses: change.addresses.map(Self.nullable), signInAddress: change.signInAddress.map(Self.nullable),
            confirmSignInAddressChange: check.requiresConfirmation ? true : nil)
        return try await answer("updateConfig") {
            try await updateConfig(headers: .init(xMarfaInstanceId: instanceID), body: .json(body)).ok.body.json
        }
    }

    private static func nullable<Value: Codable & Hashable & Sendable>(_ change: SettingChange<Value>) -> MarfaNullable<
        Value
    > {
        switch change {
        case .set(let value): .value(value)
        case .clear: .null
        }
    }
}
