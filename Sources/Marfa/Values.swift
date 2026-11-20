import Foundation
internal import MarfaCore

/// Every way the working copy refuses or fails. `code` is the server's refusal code, where the server answered.
///
/// Four properties say what an error means for an app, so that it needs no list of cases of its own:
///
/// - ``isOffline``: the server could not be reached, or its answer did not arrive. A write may still have reached
///   the server.
/// - ``isKeyRefusal``: the key or sign-in no longer works. Asking again cannot clear it; the person signs in
///   again or the app gets a new key. It is `true` for `unauthorized`, `signedOut`, and a `copyExpired` or
///   `streamIncomplete` whose reason is `credential_ended`. It is never `true` for `forbidden`: the server answers
///   a revoked or expired key with 401, and every 403 means the key is valid but lacks a permission.
/// - ``isTransient``: asking again later can clear it, with nothing changed. It is the rule the core's own
///   follow waits out, with `noConnection`, `keyChanging` and `storeBusy` added. No error is both a key refusal and transient,
///   and every offline error is transient.
/// - ``isHydrationNeeded``: the copy must be hydrated before it can be caught up or followed. Asking again cannot
///   clear it. It is `true` for `copyExpired` (unless its reason is `credential_ended`, which is a key refusal),
///   `instanceChanged`, `noCursor`, `hydrationIncomplete` and `firstSyncWaiting`, and never for a key refusal or
///   a transient error.
public enum MarfaError: Error, Sendable, Hashable, LocalizedError {
    /// The server has no such row, route or name (404).
    case notFound(code: String, message: String, server: ServerAnswer?)
    /// The server does not accept the key or token (401). A revoked or expired key gets this refusal.
    case unauthorized(code: String, message: String, server: ServerAnswer?)
    /// The key is valid but lacks the permission the call needs (403), such as `type_not_permitted`.
    case forbidden(code: String, message: String, server: ServerAnswer?)
    /// The server refused the values sent (400 or 422), or the copy refused them before sending, as the server
    /// would.
    ///
    /// `details` holds what the server's `error.details` holds for the same refusal, for each
    /// `edge_constraint_violation` and `edge_cycle` the copy gives itself (an edge check, an edge write, a move
    /// check, an item create naming edges, and a type change that an edge the item holds would not fit), so an app
    /// reads it one way whichever refused:
    ///
    /// - `edge_constraint_violation` for an end of a type the edge type does not admit: `edge_type`,
    ///   `from_type` or `to_type`, and `allowed`, the type constraints of that end.
    /// - `edge_constraint_violation` for nesting under a flat edge type: `edge_type`, `from_id`, `from_type`
    ///   and `constraint` `"nesting"`.
    /// - `edge_constraint_violation` for an edge of the same type, from end and to end the copy already shows:
    ///   `edge_type`, `from_id`, `to_id` and `constraint` `"duplicate"`.
    /// - `edge_constraint_violation` for an end that already holds the one edge of the type it may: `edge_type`,
    ///   `from_id` or `to_id` (the end that is full) and `constraint` `"cardinality"`.
    /// - `edge_cycle`: `edge_type`, `from_id` and `to_id` for a longer cycle, and `edge_type` alone for an
    ///   edge from an item to itself.
    ///
    /// It is `nil` for every other refusal, including one the server answers to a request sent to it directly.
    case validation(code: String, message: String, details: JSONValue?, server: ServerAnswer?)
    /// The copy's type catalog holds no type of the name given.
    case unknownType(message: String, server: ServerAnswer?)
    /// The server asks the client to slow down (429), for `retryAfterSeconds` where it says.
    case rateLimited(code: String, message: String, retryAfterSeconds: UInt64?, server: ServerAnswer?)
    /// Another answer from the server, with its status and code. A status of 500 or more, or 408, is transient.
    case server(status: UInt16, code: String, message: String, details: JSONValue?, server: ServerAnswer?)
    /// Reading or writing a local file failed.
    case io(message: String)
    /// The request did not reach the server, or its answer did not come back in time.
    case network(message: String)
    /// A response from something in front of the server, without its contract.
    case unnamed(status: UInt16, message: String, server: ServerAnswer?)
    /// An answer or a stored value could not be read.
    case decoding(message: String)
    /// The store could not be opened, read or written.
    case store(message: String)
    /// Another process holds the store while this call needed it.
    case storeBusy(message: String)
    /// SQLite cannot read the store at `path`, or a set-aside of it stopped part way. `path` is empty where the
    /// damage was met part way through a call, which does not know the path: ``WorkingCopy/check(store:)`` names it.
    /// `unsent` counts the writes the server has not taken, `nil` where the queue cannot be read whole.
    /// ``WorkingCopy/setAsideDamaged(store:)`` keeps the store and carries the writes it can read, and
    /// ``WorkingCopy/unsentWrites(in:)`` lists them so the person can see what a removal would lose.
    ///
    /// `setAsideStopped` is `true` while a file stands where a set-aside carries the store, so the app offers no
    /// removal or replacement: ``WorkingCopy/removeLosingAll(store:)``, ``WorkingCopy/remove(store:confirming:)`` and
    /// replacing the store refuse until ``WorkingCopy/setAsideDamaged(store:)`` is called again and finishes it. It is
    /// `false` for any other damage. Test it, never the text of `reason`.
    case storeDamaged(path: String, reason: String, unsent: UInt64?, setAsideStopped: Bool, message: String)
    /// The device has no room left to write the store.
    case storageFull(message: String)
    /// The keychain no longer holds a sign-in for `origin`, or the server ended it; sign in again.
    case signedOut(origin: String, message: String)
    /// The keychain cannot be used.
    case noKeychain(message: String)
    /// The server answered with a redirect, which is not followed, so the key goes nowhere else.
    case redirected(origin: String, status: UInt16, location: String?, message: String, server: ServerAnswer?)
    /// The call needs a server, and the copy was opened without one.
    case noServer(message: String)
    /// The copy holds no position in the server's events; hydrate first.
    case noCursor(message: String)
    /// A read by id asked for a row this copy does not hold while a hydration is still filling it, so the row may
    /// yet arrive. Reads that list or search answer the rows that have arrived and say `.partial` instead, except reads
    /// of a view's items, groups or search hits, which throw it while a hydration fills the copy and while the copy
    /// is stale. An edge write throws it too until the copy is whole, as does an item write to a row the copy does
    /// not hold.
    case hydrationIncomplete(message: String)
    /// The copy holds no type catalog; a hydration reads the server's catalog.
    case noCatalog(message: String)
    /// The store at `path` has a shape this build cannot read. `unsent`
    /// names the writes another build can still send, where the queue is readable.
    case wrongSchema(path: String, reason: String, unsent: UInt64?, message: String)
    /// Another process, or another open copy in this one, holds the store's writer role, so this copy may only
    /// read.
    case readingHandle(message: String)
    /// ``WorkingCopy/remove(store:confirming:)`` found a store whose unsent writes are not the ones the person was
    /// shown, in any field, and left it as it was. `unsent` is how many the store holds now, `nil` where they
    /// cannot be read, and such a store is never removed. Read them again with ``WorkingCopy/unsentWrites(in:)``,
    /// show them to the person and ask again.
    case unsentDiffers(path: String, unsent: UInt64?, message: String)
    /// Hydration is needed to make the copy current; its queue is kept. `reason`
    /// is an open string, such as `reach_changed`, `credential_ended` or `catchup_too_old`; another instance at
    /// the server's address is ``instanceChanged(message:server:)`` instead. A stale copy
    /// (`catchup_too_old`) refuses a drain and a catch-up this way until a hydration has filled it again.
    /// The catch-up that first detects an aged-out cursor gives a descriptive reason; read `status().hydration`
    /// to distinguish `.stale` from other expired copies. A held `changes()` stream fills a stale copy again by
    /// itself when its follow finds the cursor aged out, and is told this error where it does not.
    case copyExpired(reason: String, message: String, server: ServerAnswer?)
    /// The server ended the event stream early, for `reason`, such as `credential_ended`.
    case streamIncomplete(reason: String, message: String, server: ServerAnswer?)
    /// The store or file belongs to the server `expected`, not to `got`.
    case wrongServer(expected: String, got: String, message: String)
    /// The item is whole and its bytes are not here, nor can they be fetched.
    case bytesAbsent(hash: String, reason: String, message: String)
    /// The volume holding the file cache has less room than a fetch still has to receive.
    case noRoom(hash: String, size: UInt64, free: UInt64, message: String)
    /// The server speaks a contract this build was not made for, and its
    /// answer was not read. `served` is the contract the answer named, or nil
    /// where a success named none. Where `writeSent`, the answer was to a
    /// write, which may have taken effect: it stays queued, and goes again
    /// under its idempotency key once the app speaks the server's contract.
    /// `status` is nil when the failure carries no HTTP status.
    case contractMismatch(
        served: String?, expected: UInt64, status: UInt16?, writeSent: Bool, message: String, server: ServerAnswer?)
    /// The server's release is older than the oldest this build works with, so nothing was asked of it beyond
    /// its root. `served` is the release the server's root names and `oldest` the oldest release this build works
    /// with, both such as `0.0.77`.
    ///
    /// Asking again cannot clear it: the server must be updated, or the app must use a build made for it. Show the
    /// person ``message``, which names both releases, or say that the server needs updating.
    case serverTooOld(served: String, oldest: String, message: String)
    /// A several-item trash named a preview that no longer matches what the trash would take (409
    /// `trash_plan_changed`): an item or something it takes changed since ``Items/previewTrash(ids:)``. Nothing was
    /// trashed. Preview again, show the person the new preview, and trash that.
    case trashPlanChanged(message: String, server: ServerAnswer?)
    /// A write was refused, queueing and sending nothing, because a several-item trash or a purge of the item is
    /// out (`validation` with the code `item_being_removed`). `id` names the item, or is `nil` where a trash
    /// whose preview cut what it takes holds every item. Ask again once the call that holds the item returns.
    case itemBeingRemoved(id: String?, message: String)
    /// The caller canceled the call before it finished.
    case canceled(message: String)
    /// A folder's first sync waits for the person to confirm it, so the call that would write or send for it
    /// was refused.
    case firstSyncWaiting(message: String)
    /// A folder's sync is paused, so the call that would read the server's side or write either side was refused.
    /// Nothing was sent or written. ``Folders/resume(_:)`` lets the sync go on.
    case syncPaused(message: String)
    /// A value given to the call cannot be used, such as an unwritable JSON value or a malformed argument.
    case invalid(message: String)
    /// The app's renewer could not renew the sign-in, and the sign-in is kept. ``RenewalRefusalReason`` says why.
    ///
    /// Queued writes stay queued, and the renewer is asked again on the next attempt. Use `reason` to choose text
    /// for people. `message` is diagnostic and can include an address.
    case renewalRefused(reason: RenewalRefusalReason, message: String)
    /// The copy lacks data needed for a local count. ``WorkingCopy/counts(of:_:)`` handles this error by asking
    /// the copy's server.
    case notAnswerable(message: String)
    /// The core itself went wrong, such as a panic it caught at its boundary, so the call ended without an answer.
    ///
    /// It is never the app's input or the server's answer, so it is neither ``isTransient`` nor the caller's mistake:
    /// asking again with nothing changed is not known to help. Report it.
    case fault(message: String)
    /// The call came while ``WorkingCopy/use(_:)`` replaced the copy's sign-in, and was not made. Ask again once
    /// the change is done.
    case keyChanging(message: String)
    /// The server refused a write made against a version of the row that is no longer current (409
    /// `version_conflict`). Read the row again and decide what to write.
    case versionConflict(message: String, server: ServerAnswer?)
    /// Another Marfa instance answers at the server's address (409 `instance_changed`), so the copy needs a
    /// hydration from it. Its queue is kept.
    case instanceChanged(message: String, server: ServerAnswer?)
    /// The working copy was closed, or failed to reopen its store with a new
    /// key; it is gone for good, and the app opens the store again.
    case closed(message: String)
    /// A call that needs the server found the device offline, so nothing was sent.
    case noConnection(message: String)
    /// The server wants the owner to confirm it is them before it acts: the owner signed in longer ago than the
    /// act allows (401 `insufficient_user_authentication`, RFC 9470), and `maxAgeSeconds` is how recently they must
    /// have signed in.
    ///
    /// A ``Server`` that was told how to show the sign-in with ``Server/confirming(from:prefersEphemeralWebBrowserSession:)``
    /// signs the owner in again and sends the call once more, so an app sees this only when it gave no way to show
    /// the sheet, when the sign-in has no browser redirect, or when the server asks again after the owner confirmed.
    /// Asking again with nothing changed does not clear it. A person who cancels the sheet gets
    /// ``canceled(message:)`` instead.
    case confirmationRequired(maxAgeSeconds: UInt64?, message: String, server: ServerAnswer?)
    /// An API key made a call that only an app the owner signed in to can make (403 `app_sign_in_required`), such as
    /// restoring a backup or moving the sign-in address.
    ///
    /// Its `message` is fixed: do this from an app you signed in to. A key has no sign-in to renew, so asking
    /// again with the key cannot clear it.
    case appSignInRequired(message: String, server: ServerAnswer?)

    /// The server could not be reached, or its answer did not arrive.
    ///
    /// A `network` error can come after the request was sent, so a write may have reached the server.
    public var isOffline: Bool {
        switch self {
        case .network, .noConnection: true
        default: false
        }
    }

    /// The key or sign-in no longer works, and asking again cannot clear it.
    ///
    /// `forbidden` is never a key refusal: the server answers a revoked or expired key with 401, and every 403
    /// means the key is valid but lacks a permission.
    public var isKeyRefusal: Bool {
        switch self {
        case .unauthorized, .signedOut: true
        case .copyExpired(let reason, _, _), .streamIncomplete(let reason, _, _): reason == "credential_ended"
        default: false
        }
    }

    /// Asking again later can clear it, with nothing changed: the rule the core's own follow waits out
    /// (`CoreError::is_environmental`), with `noConnection`, `keyChanging` and `storeBusy` added: another program held
    /// the store, and asking again later finds it free.
    ///
    /// An ``unnamed(status:message:server:)`` answer is transient whatever its status, since a gateway's 401 is not the
    /// server's word on the key.
    public var isTransient: Bool {
        switch self {
        case .network, .noConnection, .io, .storageFull, .storeBusy, .rateLimited, .unnamed, .keyChanging: true
        case .server(let status, _, _, _, _): status >= 500 || status == 408
        default: false
        }
    }

    /// The copy must be hydrated before it can be caught up or followed, and asking again cannot clear it.
    ///
    /// It is the rule ``CopyConnection/needsHydration(_:)`` follows. A `copyExpired` whose reason is
    /// `credential_ended` is a key refusal instead, which a new key clears.
    public var isHydrationNeeded: Bool {
        switch self {
        case .copyExpired(let reason, _, _): reason != "credential_ended"
        case .instanceChanged, .noCursor, .hydrationIncomplete, .firstSyncWaiting: true
        default: false
        }
    }

    var isRenewalRefused: Bool {
        if case .renewalRefused = self { true } else { false }
    }

    /// The error's message.
    ///
    /// For a renewal refusal, use `reason` to choose text for people.
    public var message: String {
        switch self {
        case .notFound(_, let message, _), .unauthorized(_, let message, _), .forbidden(_, let message, _),
            .validation(_, let message, _, _), .unknownType(let message, _), .rateLimited(_, let message, _, _),
            .server(_, _, let message, _, _), .io(let message), .network(let message), .unnamed(_, let message, _),
            .decoding(let message),
            .store(let message), .storeBusy(let message), .storeDamaged(_, _, _, _, let message),
            .storageFull(let message), .signedOut(_, let message),
            .noKeychain(let message), .redirected(_, _, _, let message, _),
            .noServer(let message), .noCursor(let message), .hydrationIncomplete(let message), .noCatalog(let message),
            .wrongSchema(_, _, _, let message), .readingHandle(let message), .unsentDiffers(_, _, let message),
            .copyExpired(_, let message, _),
            .streamIncomplete(_, let message, _), .wrongServer(_, _, let message), .bytesAbsent(_, _, let message),
            .noRoom(_, _, _, let message),
            .contractMismatch(_, _, _, _, let message, _), .serverTooOld(_, _, let message),
            .trashPlanChanged(let message, _), .itemBeingRemoved(_, let message),
            .canceled(let message), .firstSyncWaiting(let message), .syncPaused(let message),
            .invalid(let message), .renewalRefused(_, let message), .notAnswerable(let message), .fault(let message),
            .keyChanging(let message),
            .versionConflict(let message, _),
            .instanceChanged(let message, _), .closed(let message), .noConnection(let message),
            .confirmationRequired(_, let message, _), .appSignInRequired(let message, _):
            message
        }
    }

    /// What the server answered, where a server's answer is what failed the call.
    ///
    /// It is the answer's status, its refusal code and its `error.details`, as the server sent them. It is `nil` for
    /// a failure the device met itself, and for an answer the call did not read.
    public var server: ServerAnswer? {
        switch self {
        case .notFound(_, _, let server), .unauthorized(_, _, let server), .forbidden(_, _, let server),
            .validation(_, _, _, let server), .unknownType(_, let server), .rateLimited(_, _, _, let server),
            .server(_, _, _, _, let server), .unnamed(_, _, let server), .redirected(_, _, _, _, let server),
            .copyExpired(_, _, let server), .streamIncomplete(_, _, let server),
            .contractMismatch(_, _, _, _, _, let server), .versionConflict(_, let server),
            .instanceChanged(_, let server), .confirmationRequired(_, _, let server),
            .appSignInRequired(_, let server), .trashPlanChanged(_, let server):
            server
        case .io, .network, .decoding, .store, .storeBusy, .storeDamaged, .storageFull, .signedOut, .noKeychain,
            .noServer, .noCursor, .hydrationIncomplete, .noCatalog, .wrongSchema, .readingHandle, .unsentDiffers,
            .wrongServer, .bytesAbsent, .noRoom, .canceled, .firstSyncWaiting, .syncPaused, .invalid, .renewalRefused,
            .notAnswerable,
            .fault, .keyChanging, .serverTooOld, .itemBeingRemoved,
            .closed, .noConnection:
            nil
        }
    }

    /// The canonical error name shared with the core and CLI.
    ///
    /// Associated `code` values remain the server's refusal codes.
    public func code() -> String {
        let core: MarfaCore.MarfaError
        switch self {
        case .notFound(let code, let message, let server):
            core = .NotFound(code: code, message: message, server: server?.core)
        case .unauthorized(let code, let message, let server):
            core = .Unauthorized(code: code, message: message, server: server?.core)
        case .forbidden(let code, let message, let server):
            core = .Forbidden(code: code, message: message, server: server?.core)
        case .validation(let code, let message, let details, let server):
            core = .Validation(code: code, message: message, details: details?.core, server: server?.core)
        case .unknownType(let message, let server): core = .UnknownType(message: message, server: server?.core)
        case .rateLimited(let code, let message, let retryAfterSeconds, let server):
            core = .RateLimited(
                code: code, message: message, retryAfterSeconds: retryAfterSeconds, server: server?.core)
        case .server(let status, let code, let message, let details, let server):
            core = .Server(
                status: status, code: code, message: message, details: details?.core, server: server?.core)
        case .io(let message): core = .Io(message: message)
        case .network(let message): core = .Network(message: message)
        case .unnamed(let status, let message, let server):
            core = .Unnamed(status: status, message: message, server: server?.core)
        case .decoding(let message): core = .Decoding(message: message)
        case .store(let message): core = .Store(message: message)
        case .storeBusy(let message): core = .StoreBusy(message: message)
        case .storeDamaged(let path, let reason, let unsent, let setAsideStopped, let message):
            core = .StoreDamaged(
                path: path, reason: reason, unsent: unsent, setAsideStopped: setAsideStopped, message: message)
        case .storageFull(let message): core = .StorageFull(message: message)
        case .signedOut(let origin, let message): core = .SignedOut(origin: origin, message: message)
        case .noKeychain(let message): core = .NoKeychain(message: message)
        case .redirected(let origin, let status, let location, let message, let server):
            core = .Redirected(
                origin: origin, status: status, location: location, message: message, server: server?.core)
        case .noServer(let message): core = .NoServer(message: message)
        case .noCursor(let message): core = .NoCursor(message: message)
        case .hydrationIncomplete(let message): core = .HydrationIncomplete(message: message)
        case .noCatalog(let message): core = .NoCatalog(message: message)
        case .wrongSchema(let path, let reason, let unsent, let message):
            core = .WrongSchema(path: path, reason: reason, unsent: unsent, message: message)
        case .readingHandle(let message): core = .ReadingHandle(message: message)
        case .unsentDiffers(let path, let unsent, let message):
            core = .UnsentDiffers(path: path, unsent: unsent, message: message)
        case .copyExpired(let reason, let message, let server):
            core = .CopyExpired(reason: reason, message: message, server: server?.core)
        case .streamIncomplete(let reason, let message, let server):
            core = .StreamIncomplete(reason: reason, message: message, server: server?.core)
        case .wrongServer(let expected, let got, let message):
            core = .WrongServer(expected: expected, got: got, message: message)
        case .bytesAbsent(let hash, let reason, let message):
            core = .BytesAbsent(hash: hash, reason: reason, message: message)
        case .noRoom(let hash, let size, let free, let message):
            core = .NoRoom(hash: hash, size: size, free: free, message: message)
        case .contractMismatch(let served, let expected, let status, let writeSent, let message, let server):
            core = .ContractMismatch(
                served: served, expected: expected, status: status, writeSent: writeSent, message: message,
                server: server?.core)
        case .serverTooOld(let served, let oldest, let message):
            core = .ServerTooOld(served: served, oldest: oldest, message: message)
        case .trashPlanChanged(let message, let server):
            core = .Server(
                status: 409, code: "trash_plan_changed", message: message, details: server?.details?.core,
                server: server?.core)
        case .itemBeingRemoved(let id, let message):
            core = .Validation(
                code: "item_being_removed", message: message,
                details: id.map { JSONValue.object(["id": .string($0)]).core }, server: nil)
        case .canceled(let message): core = .Canceled(message: message)
        case .firstSyncWaiting(let message): core = .FirstSyncWaiting(message: message)
        case .syncPaused(let message): core = .SyncPaused(message: message)
        case .invalid(let message): core = .Invalid(message: message)
        case .renewalRefused(let reason, let message):
            core = .RenewalRefused(reason: reason.core, message: message)
        case .notAnswerable(let message): core = .NotAnswerable(message: message)
        case .fault(let message): core = .Fault(message: message)
        case .versionConflict(let message, let server):
            core = .Server(
                status: 409, code: "version_conflict", message: message, details: server?.details?.core,
                server: server?.core)
        case .instanceChanged(let message, let server):
            core = .CopyExpired(reason: "instance_changed", message: message, server: server?.core)
        case .keyChanging: return "key_changing"
        case .closed: return "closed"
        case .noConnection: return "no_connection"
        case .confirmationRequired(_, let message, let server):
            core = .Unauthorized(code: "insufficient_user_authentication", message: message, server: server?.core)
        case .appSignInRequired(let message, let server):
            core = .Forbidden(code: "app_sign_in_required", message: message, server: server?.core)
        }
        return core.code()
    }

    public var errorDescription: String? { message }

    init(_ error: MarfaCore.MarfaError) {
        switch error {
        case .NotFound(let code, let message, let server):
            self = .notFound(code: code, message: message, server: server.map(ServerAnswer.init))
        case .Unauthorized(let code, let message, let server):
            self = .unauthorized(code: code, message: message, server: server.map(ServerAnswer.init))
        case .Forbidden(let code, let message, let server):
            self = .forbidden(code: code, message: message, server: server.map(ServerAnswer.init))
        case .Validation("item_being_removed", let message, let details, _):
            self = .itemBeingRemoved(id: details.map(JSONValue.init)?.object?["id"]?.string, message: message)
        case .Validation(let code, let message, let details, let server):
            self = .validation(
                code: code, message: message, details: details.map(JSONValue.init),
                server: server.map(ServerAnswer.init))
        case .UnknownType(let message, let server):
            self = .unknownType(message: message, server: server.map(ServerAnswer.init))
        case .RateLimited(let code, let message, let retryAfterSeconds, let server):
            self = .rateLimited(
                code: code, message: message, retryAfterSeconds: retryAfterSeconds,
                server: server.map(ServerAnswer.init))
        case .Server(409, "version_conflict", let message, _, let server):
            self = .versionConflict(message: message, server: server.map(ServerAnswer.init))
        case .Server(409, "trash_plan_changed", let message, _, let server):
            self = .trashPlanChanged(message: message, server: server.map(ServerAnswer.init))
        case .Server(409, "instance_changed", let message, _, let server):
            self = .instanceChanged(message: message, server: server.map(ServerAnswer.init))
        case .Server(let status, let code, let message, let details, let server):
            self = .server(
                status: status, code: code, message: message, details: details.map(JSONValue.init),
                server: server.map(ServerAnswer.init))
        case .Io(let message): self = .io(message: message)
        case .Network(let message): self = .network(message: message)
        case .Unnamed(let status, let message, let server):
            self = .unnamed(status: status, message: message, server: server.map(ServerAnswer.init))
        case .Decoding(let message): self = .decoding(message: message)
        case .Store(let message): self = .store(message: message)
        case .StoreBusy(let message): self = .storeBusy(message: message)
        case .StoreDamaged(let path, let reason, let unsent, let setAsideStopped, let message):
            self = .storeDamaged(
                path: path, reason: reason, unsent: unsent, setAsideStopped: setAsideStopped, message: message)
        case .StorageFull(let message): self = .storageFull(message: message)
        case .SignedOut(let origin, let message): self = .signedOut(origin: origin, message: message)
        case .NoKeychain(let message): self = .noKeychain(message: message)
        case .Redirected(let origin, let status, let location, let message, let server):
            self = .redirected(
                origin: origin, status: status, location: location, message: message,
                server: server.map(ServerAnswer.init))
        case .NoServer(let message): self = .noServer(message: message)
        case .NoCursor(let message): self = .noCursor(message: message)
        case .HydrationIncomplete(let message): self = .hydrationIncomplete(message: message)
        case .NoCatalog(let message): self = .noCatalog(message: message)
        case .WrongSchema(let path, let reason, let unsent, let message):
            self = .wrongSchema(path: path, reason: reason, unsent: unsent, message: message)
        case .ReadingHandle(let message): self = .readingHandle(message: message)
        case .UnsentDiffers(let path, let unsent, let message):
            self = .unsentDiffers(path: path, unsent: unsent, message: message)
        case .CopyExpired("instance_changed", let message, let server):
            self = .instanceChanged(message: message, server: server.map(ServerAnswer.init))
        case .CopyExpired(let reason, let message, let server):
            self = .copyExpired(reason: reason, message: message, server: server.map(ServerAnswer.init))
        case .StreamIncomplete(let reason, let message, let server):
            self = .streamIncomplete(reason: reason, message: message, server: server.map(ServerAnswer.init))
        case .WrongServer(let expected, let got, let message):
            self = .wrongServer(expected: expected, got: got, message: message)
        case .BytesAbsent(let hash, let reason, let message):
            self = .bytesAbsent(hash: hash, reason: reason, message: message)
        case .NoRoom(let hash, let size, let free, let message):
            self = .noRoom(hash: hash, size: size, free: free, message: message)
        case .ContractMismatch(let served, let expected, let status, let writeSent, let message, let server):
            self = .contractMismatch(
                served: served, expected: expected, status: status, writeSent: writeSent, message: message,
                server: server.map(ServerAnswer.init))
        case .ServerTooOld(let served, let oldest, let message):
            self = .serverTooOld(served: served, oldest: oldest, message: message)
        case .Canceled(let message): self = .canceled(message: message)
        case .FirstSyncWaiting(let message): self = .firstSyncWaiting(message: message)
        case .SyncPaused(let message): self = .syncPaused(message: message)
        case .Invalid(let message): self = .invalid(message: message)
        case .RenewalRefused(let reason, let message):
            self = .renewalRefused(reason: RenewalRefusalReason(reason), message: message)
        case .NotAnswerable(let message): self = .notAnswerable(message: message)
        case .Fault(let message): self = .fault(message: message)
        }
    }
}

/// Why a renewal of the sign-in failed with ``MarfaError/renewalRefused(reason:message:)``.
public enum RenewalRefusalReason: Sendable, Hashable, CaseIterable {
    /// The server refused the renewal without ending the sign-in.
    case refused
    /// The server answered the renewal with a redirect, which is never followed.
    case redirected
    /// The server's answer to the renewal, or its sign-in metadata, could not be read.
    case unreadable

    init(_ core: RenewalFailure) {
        switch core {
        case .refused: self = .refused
        case .redirected: self = .redirected
        case .unreadable: self = .unreadable
        }
    }

    var core: RenewalFailure {
        switch self {
        case .refused: .refused
        case .redirected: .redirected
        case .unreadable: .unreadable
        }
    }
}

/// What a server answered to a request: its status, its refusal code, its `error.details` and its `X-Request-ID`.
public struct ServerAnswer: Sendable, Hashable {
    public var status: UInt16
    public var code: String?
    public var details: JSONValue?
    /// The server's `X-Request-ID`, which a report of a problem can quote. `nil` where the server sent none.
    public var requestId: String?

    public init(status: UInt16, code: String?, details: JSONValue?, requestId: String?) {
        self.status = status
        self.code = code
        self.details = details
        self.requestId = requestId
    }

    init(_ core: MarfaCore.ServerAnswer) {
        self.init(
            status: core.status, code: core.code, details: core.details.map(JSONValue.init),
            requestId: core.requestId)
    }

    var core: MarfaCore.ServerAnswer {
        MarfaCore.ServerAnswer(status: status, code: code, details: details?.core, requestId: requestId)
    }
}

/// The rows a read of the copy answered, and whether the copy was whole when it answered.
///
/// A list or a search made while a hydration fills the copy answers the rows that have arrived and says
/// `.partial`, so an app can show them with a sign that more are coming, and read again on
/// `.refreshed(.hydrated)`. A copy whose cursor the event log let go answers what it held and says `.stale`. `Rows` is a random-access collection of its `rows`, so it iterates, maps and counts as an
/// array does.
public struct Rows<Row: Sendable>: Sendable {
    public var rows: [Row]
    public var completeness: Completeness

    public init(_ rows: [Row] = [], completeness: Completeness = .complete) {
        self.rows = rows
        self.completeness = completeness
    }
}

extension Rows {
    /// What a ``Reading`` shows until its first read ends: no rows, and `.partial` because nothing has been read.
    public static var unread: Rows { Rows(completeness: .partial) }
}

extension Rows: Equatable where Row: Equatable {}
extension Rows: Hashable where Row: Hashable {}

extension Rows: ExpressibleByArrayLiteral {
    public init(arrayLiteral rows: Row...) {
        self.init(rows)
    }
}

extension Rows: RandomAccessCollection {
    public var startIndex: Int { rows.startIndex }
    public var endIndex: Int { rows.endIndex }
    public subscript(position: Int) -> Row { rows[position] }
}

extension MarfaCore.Found {
    var answer: Rows<SearchHit> { Rows(hits.map(SearchHit.init), completeness: Completeness(completeness)) }
}

extension Item: Identifiable {}
extension Edge: Identifiable {}

/// A change to an edge's properties, a move of one of its ends, or both, and
/// the version it was read at.
///
/// A move is one write that carries the end it moves, so the end never holds
/// no edge or two. An end the edge already holds moves nothing and is not
/// sent. An edit that names no property and no end other than those the
/// edge holds queues nothing: ``Edges/update(_:_:)`` returns `nil`. Only one
/// end moves at a time, so the type cannot name both.
///
/// A move is refused before anything is queued, with the server's code:
/// `validation_error` where the edge's type lets the end that stays hold more
/// than one edge, such as `about`, and `edge_cycle` where the move would leave
/// the edge running from an item to itself. Otherwise the edge the move would
/// leave is judged as ``Edges/check(from:to:type:properties:id:)`` judges a
/// new one, with the edge itself left out: a move onto an item that already
/// holds the one edge of the type its end may, such as a second `supersedes`
/// edge, throws `edge_constraint_violation` with `details.constraint`
/// `"cardinality"`. ``Edges/check(_:moving:)`` answers the same without
/// queueing. A move the copy cannot judge, such as one that closes a cycle
/// through edges outside its slice, is queued and refused by the server, and
/// its verdict says why.
///
/// Once the server accepts a move of the from end, the copy expires. The drain sends
/// the writes queued behind the move first, then throws
/// `MarfaError.copyExpired` with the reason `reach_changed` once, after
/// the last. The writes are answered, and the app hydrates again. A drain
/// that ends with a wait, an unreachable server, a stopped credential or a
/// write left undelivered returns its report instead, and the next call
/// throws `copyExpired`. A move of the to end does not expire the copy.
public struct EdgeEdit: Sendable, Hashable {
    /// The end of an edge to move, and the item to move it to.
    public enum Move: Sendable, Hashable {
        case from(String)
        case to(String)
    }

    /// Each property given replaces its whole value; every other one stays as it is.
    public var properties: JSONObject
    public var baseVersion: Int64
    public var move: Move?

    public init(_ properties: JSONObject = [:], baseVersion: Int64, move: Move? = nil) {
        self.properties = properties
        self.baseVersion = baseVersion
        self.move = move
    }

    var core: MarfaCore.EdgeEdit {
        MarfaCore.EdgeEdit(properties: properties.core, baseVersion: baseVersion, moves: move.map(Self.coreMove))
    }

    static func coreMove(_ move: Move) -> MarfaCore.EdgeMove {
        switch move {
        case .from(let id): MarfaCore.EdgeMove(end: .from, to: id)
        case .to(let id): MarfaCore.EdgeMove(end: .to, to: id)
        }
    }
}
