import Foundation
@_spi(MarfaSDKTestSupport) import MarfaSDK

/// Test-support construction of the payload a conflict resolver receives.
///
/// A `ConflictResolver` registered on the client is the app's own code, and
/// until now the only way to run it was to make a real server conflict on
/// demand. So the resolver an app installs, which is the one a replayed
/// `.callback` update reaches, was the piece nobody could test.
extension MarfaSDKTest {

    /// Builds a ``ConflictData`` for exercising a resolver directly.
    ///
    /// Defaults describe the ordinary shape: one field edited on both sides,
    /// the client's value in `clientPatch` and the server's in `current`.
    /// `ancestor` defaults to an empty snapshot at version 1 — resolvers that
    /// read it should pass one.
    public static func makeConflictData(
        itemId: String,
        conflictingFields: [String],
        clientPatch: [String: JSONValue],
        serverProperties: [String: JSONValue],
        serverVersion: Int = 2,
        ancestor: ConflictSnapshot = ConflictSnapshot(properties: [:], version: 1),
        mergePolicy: MergePolicy? = nil
    ) -> ConflictData {
        ConflictData(
            itemId: itemId,
            current: ConflictSnapshot(
                properties: serverProperties,
                version: serverVersion
            ),
            ancestor: ancestor,
            conflictingFields: conflictingFields,
            clientPatch: clientPatch,
            mergePolicy: mergePolicy
        )
    }
}
