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
///    as this instance. It answers an ``AddressChangeCheck``, which holds the change it checked.
/// 2. Show the owner the check's `consequences` and, once they agree, ``Client/apply(_:expecting:)`` the check. It
///    makes exactly the change that was checked, and confirms the move for the owner when the server asks for that.
///    The server wants the owner to have signed in within the last five minutes: a ``Server`` set up with
///    ``Server/confirming(from:prefersEphemeralWebBrowserSession:)`` signs them in again by itself, and a key is
///    refused with ``MarfaError/appSignInRequired(message:server:)``.
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

/// What the server said a change to the addresses would do, together with the change it said it about.
///
/// ``Client/apply(_:expecting:)`` makes the change held here and no other, so the owner's agreement to what the check
/// showed covers what is written. Only ``Client/check(_:)`` makes one.
public struct AddressChangeCheck: Sendable, Hashable {
    /// The change that was checked, as it was when it was sent.
    public let change: AddressChange
    /// The server's answer: what the change would do, whether it needs the owner's confirmation, and whether the new
    /// sign-in address answers as this instance.
    public let answer: Components.Schemas.AddressCheck
}

extension Client {
    /// What `change` would do, and whether its new sign-in address answers as this instance.
    ///
    /// Writes nothing.
    ///
    /// Needs `config.manage`. The check's `answer.requiresConfirmation` says whether a write needs the owner's agreement,
    /// and `answer.signInAddressCheck.passed` is `false` when the new address does not answer as this instance, with its
    /// `reason`; a write of such a change is refused with the code `sign_in_address_check_failed`.
    public func check(_ change: AddressChange) async throws(MarfaError) -> AddressChangeCheck {
        let body = Components.Schemas.AddressCheckRequest(
            signInAddress: change.signInAddress.map(Self.nullable), addresses: change.addresses.map(Self.nullable))
        let checked = try await answer("checkAddressChange") {
            try await checkAddressChange(body: .json(body)).ok.body.json
        }
        return AddressChangeCheck(change: change, answer: checked)
    }

    /// Makes the change `check` holds, confirming a move of the sign-in address when the check says the server asks
    /// for that, and answers the settings as stored.
    ///
    /// Sends the change as ``check(_:)`` sent it, so a move the owner has not been shown is not made or confirmed for
    /// them. `instanceID` makes the server refuse the change with ``MarfaError/instanceChanged(message:server:)`` when
    /// another instance now answers at this address.
    public func apply(
        _ check: AddressChangeCheck, expecting instanceID: String? = nil
    ) async throws(MarfaError) -> Components.Schemas.InstanceConfig {
        let change = check.change
        let body = Operations.UpdateConfig.Input.Body.JsonPayload(
            addresses: change.addresses.map(Self.nullable), signInAddress: change.signInAddress.map(Self.nullable),
            confirmSignInAddressChange: check.answer.requiresConfirmation ? true : nil)
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
