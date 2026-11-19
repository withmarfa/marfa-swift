/// What an app's own error reporting may say of a ``MarfaError``: a type and a sentence fixed in the source, and a
/// code.
///
/// An error's own `message`, `path`, `origin`, `location`, `hash` and every other value it carries can hold a note's
/// words, a file name, an address or an id, so none of them reaches `type` or `sentence`: both are `StaticString`s
/// chosen by an exhaustive `switch`, and a new `MarfaError` case fails to compile until someone writes both for it.
/// The only carried value that can reach `code` is a refusal code with the shape of one.
public struct FixedErrorText: Sendable, Hashable {
    /// The case's stable name, such as `not_found`.
    ///
    /// It is the word ``MarfaError/code()`` answers.
    public let type: String
    /// One sentence that says what went wrong, with no value from the error in it.
    public let sentence: String
    /// The server's refusal code where the error carries one and it has the shape of a code, otherwise `type`.
    ///
    /// A code is lowercase letters and underscores only, at most 48 characters, so an id, a hash, a path or a
    /// sentence that arrived in its place never reaches it.
    public let code: String

    init(type: StaticString, sentence: StaticString, serverCode: String? = nil) {
        self.type = "\(type)"
        self.sentence = "\(sentence)"
        if let serverCode, Self.isCode(serverCode) {
            code = serverCode
        } else {
            code = self.type
        }
    }

    static func isCode(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...48).contains(bytes.count) else { return false }
        return bytes.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }
    }
}

extension MarfaError {
    /// The text an app's own error reporting may carry for this error.
    ///
    /// See ``FixedErrorText``.
    public var fixedText: FixedErrorText {
        switch self {
        case .notFound(let code, _, _):
            FixedErrorText(type: "not_found", sentence: "nothing was found at what the request named", serverCode: code)
        case .unauthorized(let code, _, _):
            FixedErrorText(type: "unauthorized", sentence: "the server did not accept the credential", serverCode: code)
        case .forbidden(let code, _, _):
            FixedErrorText(
                type: "forbidden", sentence: "the request was refused because the credential lacks a permission",
                serverCode: code)
        case .validation(let code, _, _, _):
            FixedErrorText(type: "validation", sentence: "the request was rejected as invalid", serverCode: code)
        case .unknownType:
            FixedErrorText(type: "unknown_type", sentence: "the server does not know the type that was named")
        case .rateLimited(let code, _, _, _):
            FixedErrorText(type: "rate_limited", sentence: "the server rate limited the request", serverCode: code)
        case .server(_, let code, _, _, _):
            FixedErrorText(type: "server", sentence: "the server failed to complete the request", serverCode: code)
        case .io:
            FixedErrorText(type: "io", sentence: "reading or writing a file or a stream failed")
        case .network:
            FixedErrorText(type: "network", sentence: "the server could not be reached, or did not answer in time")
        case .unnamed:
            FixedErrorText(type: "unnamed_answer", sentence: "the answer did not come from a Marfa server")
        case .decoding:
            FixedErrorText(type: "decoding", sentence: "an answer could not be decoded")
        case .store:
            FixedErrorText(type: "store", sentence: "the local working copy reported a fault")
        case .storeBusy:
            FixedErrorText(type: "store_busy", sentence: "another process holds the working copy's store")
        case .storeDamaged:
            FixedErrorText(type: "store_damaged", sentence: "the working copy's store could not be read")
        case .storageFull:
            FixedErrorText(type: "storage_full", sentence: "local storage is full")
        case .signedOut:
            FixedErrorText(type: "signed_out", sentence: "the sign-in has ended")
        case .noKeychain:
            FixedErrorText(type: "no_keychain", sentence: "the system's credential storage is unavailable")
        case .redirected:
            FixedErrorText(type: "redirect", sentence: "the server answered with a redirect, which is not followed")
        case .noServer:
            FixedErrorText(type: "no_server", sentence: "no server was named")
        case .noCursor:
            FixedErrorText(type: "no_cursor", sentence: "the working copy has no event cursor yet")
        case .hydrationIncomplete:
            FixedErrorText(type: "hydration_incomplete", sentence: "the working copy's hydration did not complete")
        case .noCatalog:
            FixedErrorText(type: "no_catalog", sentence: "the working copy has never held the server's type catalog")
        case .wrongSchema:
            FixedErrorText(type: "wrong_schema", sentence: "the working copy was made by another build")
        case .readingHandle:
            FixedErrorText(type: "reading_handle", sentence: "another process holds the working copy's writer handle")
        case .unsentDiffers:
            FixedErrorText(
                type: "unsent_differs",
                sentence: "the working copy holds other writes than the ones the person was shown")
        case .copyExpired:
            FixedErrorText(type: "copy_expired", sentence: "the working copy can no longer be kept current")
        case .streamIncomplete:
            FixedErrorText(type: "stream_incomplete", sentence: "the event stream ended early")
        case .wrongServer:
            FixedErrorText(type: "wrong_server", sentence: "the working copy belongs to a different server")
        case .bytesAbsent:
            FixedErrorText(type: "bytes_absent", sentence: "a blob's bytes are not held here and could not be fetched")
        case .noRoom:
            FixedErrorText(type: "no_room", sentence: "a file does not fit in the space free")
        case .contractMismatch:
            FixedErrorText(
                type: "contract_mismatch", sentence: "the server speaks a different contract than this build")
        case .serverTooOld:
            FixedErrorText(type: "server_too_old", sentence: "the server's release is older than this build works with")
        case .trashPlanChanged:
            FixedErrorText(
                type: "server", sentence: "the items changed since the trash was previewed",
                serverCode: "trash_plan_changed")
        case .itemBeingRemoved:
            FixedErrorText(
                type: "validation", sentence: "the item is being removed by a trash or a purge",
                serverCode: "item_being_removed")
        case .canceled:
            FixedErrorText(type: "canceled", sentence: "the operation was stopped before it finished")
        case .firstSyncWaiting:
            FixedErrorText(type: "first_sync_waiting", sentence: "a folder's first sync waits for confirmation")
        case .invalid:
            FixedErrorText(type: "invalid", sentence: "a value was not accepted")
        case .notAnswerable:
            FixedErrorText(type: "not_answerable", sentence: "the working copy does not hold what a count needs")
        case .fault:
            FixedErrorText(type: "fault", sentence: "the core failed inside, and the call ended without an answer")
        case .keyChanging:
            FixedErrorText(type: "key_changing", sentence: "the call came while the working copy changed its key")
        case .versionConflict:
            FixedErrorText(
                type: "server", sentence: "the write was made against a version that is no longer current",
                serverCode: "version_conflict")
        case .instanceChanged:
            FixedErrorText(
                type: "copy_expired", sentence: "another instance answers at the server's address",
                serverCode: "instance_changed")
        case .closed:
            FixedErrorText(type: "closed", sentence: "the working copy was closed")
        case .noConnection:
            FixedErrorText(type: "no_connection", sentence: "a call that needs the server found the device offline")
        case .confirmationRequired:
            FixedErrorText(
                type: "confirmation_required", sentence: "the server asked the owner to sign in again before it acts",
                serverCode: "insufficient_user_authentication")
        case .appSignInRequired:
            FixedErrorText(
                type: "app_sign_in_required", sentence: "the call must come from an app the owner signed in to",
                serverCode: "app_sign_in_required")
        }
    }
}
