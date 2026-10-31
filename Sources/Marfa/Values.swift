import Foundation
internal import MarfaCore

/// Every way the working copy refuses or fails. `code` is the server's refusal code, where the server answered.
///
/// Three properties say what an error means for an app, so that it needs no list of cases of its own:
///
/// - ``isOffline``: the server could not be reached, or its answer did not arrive. A write may still have reached
///   the server.
/// - ``isKeyRefusal``: the key or sign-in no longer works. Asking again cannot clear it; the person signs in
///   again or the app gets a new key. It is `true` for `unauthorized`, `signedOut`, and a `copyExpired` or
///   `streamIncomplete` whose reason is `credential_ended`. It is never `true` for `forbidden`: the server answers
///   a revoked or expired key with 401, and every 403 means the key is valid but lacks a permission.
/// - ``isTransient``: asking again later can clear it, with nothing changed. It is the rule the core's own
///   follow waits out, with `noConnection` and `keyChanging` added. No error is both a key refusal and transient,
///   and every offline error is transient.
public enum MarfaError: Error, Sendable, Hashable, LocalizedError {
    /// The server has no such row, route or name (404).
    case notFound(code: String, message: String)
    /// The server does not accept the key or token (401). A revoked or expired key gets this refusal.
    case unauthorized(code: String, message: String)
    /// The key is valid but lacks the permission the call needs (403), such as `type_not_permitted`.
    case forbidden(code: String, message: String)
    /// The server refused the values sent (400 or 422).
    case validation(code: String, message: String)
    /// The copy's type catalog holds no type of the name given.
    case unknownType(message: String)
    /// The server asks the client to slow down (429), for `retryAfterSeconds` where it says.
    case rateLimited(code: String, message: String, retryAfterSeconds: UInt64?)
    /// Another answer from the server, with its status and code. A status of 500 or more, or 408, is transient.
    case server(status: UInt16, code: String, message: String)
    /// Reading or writing a local file failed.
    case io(message: String)
    /// The request did not reach the server, or its answer did not come back in time.
    case network(message: String)
    /// A response from something in front of the server, without its contract.
    case unnamed(status: UInt16, message: String)
    /// An answer or a stored value could not be read.
    case decoding(message: String)
    /// The store could not be opened, read or written.
    case store(message: String)
    /// The device has no room left to write the store.
    case storageFull(message: String)
    /// The keychain no longer holds a sign-in for `origin`, or the server ended it; sign in again.
    case signedOut(origin: String, message: String)
    /// The keychain cannot be used.
    case noKeychain(message: String)
    /// The server answered with a redirect, which is not followed, so the key goes nowhere else.
    case redirected(origin: String, status: UInt16, location: String?, message: String)
    /// The call needs a server, and the copy was opened without one.
    case noServer(message: String)
    /// The copy holds no position in the server's events; hydrate first.
    case noCursor(message: String)
    /// A read by id asked for a row this copy does not hold while a hydration is still filling it, so the row may
    /// yet arrive. Reads that list or search answer the rows that have arrived and say `.partial` instead. An edge
    /// write throws it too until the copy is whole, as does an item write to a row the copy does not hold.
    case hydrationIncomplete(message: String)
    /// The copy holds no type catalog; a hydration reads the server's catalog.
    case noCatalog(message: String)
    /// The store at `path` has a shape this build cannot read. `unsent`
    /// names the writes another build can still send, where the queue is readable.
    case wrongSchema(path: String, reason: String, unsent: UInt64?, message: String)
    /// Another process, or another open copy in this one, holds the store's writer role, so this copy may only
    /// read.
    case readingHandle(message: String)
    /// ``WorkingCopy/remove(store:unsent:)`` found a store whose unsent writes are not the number the caller
    /// agreed to lose, and left it as it was. `unsent` is the store's own count, `nil` where it cannot be read,
    /// and such a store is never removed; `agreed` is the number passed. Show the person `unsent` and ask again.
    case unsentDiffers(path: String, unsent: UInt64?, agreed: UInt64, message: String)
    /// Hydration is needed to make the copy current; its queue is kept. `reason`
    /// is an open string, such as `reach_changed`, `credential_ended` or `catchup_too_old`; another instance at
    /// the server's address is ``instanceChanged(message:)`` instead. A stale copy
    /// (`catchup_too_old`) refuses a drain and a catch-up this way until a hydration has filled it again.
    /// The catch-up that first detects an aged-out cursor gives a descriptive reason; read `status().hydration`
    /// to distinguish `.stale` from other expired copies. A held `changes()` stream fills a stale copy again by
    /// itself when its follow finds the cursor aged out, and is told this error where it does not.
    case copyExpired(reason: String, message: String)
    /// The server ended the event stream early, for `reason`, such as `credential_ended`.
    case streamIncomplete(reason: String, message: String)
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
    case contractMismatch(served: String?, expected: UInt64, status: UInt16?, writeSent: Bool, message: String)
    /// The caller canceled the call before it finished.
    case canceled(message: String)
    /// A folder's first sync waits for the person to confirm it, so the call that would write or send for it
    /// was refused.
    case firstSyncWaiting(message: String)
    /// A value given to the call cannot be used, such as an unwritable JSON value or a malformed argument.
    case invalid(message: String)
    /// The call came while ``WorkingCopy/useKey(_:)`` replaced the copy's key, and was not made. Ask again once
    /// the change is done.
    case keyChanging(message: String)
    /// The server refused a write made against a version of the row that is no longer current (409
    /// `version_conflict`). Read the row again and decide what to write.
    case versionConflict(message: String)
    /// Another Marfa instance answers at the server's address (409 `instance_changed`), so the copy needs a
    /// hydration from it. Its queue is kept.
    case instanceChanged(message: String)
    /// The working copy was closed, or failed to reopen its store with a new
    /// key; it is gone for good, and the app opens the store again.
    case closed(message: String)
    /// A call that needs the server found the device offline, so nothing was sent.
    case noConnection(message: String)

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
        case .copyExpired(let reason, _), .streamIncomplete(let reason, _): reason == "credential_ended"
        default: false
        }
    }

    /// Asking again later can clear it, with nothing changed: the rule the core's own follow waits out
    /// (`CoreError::is_environmental`), with `noConnection` and `keyChanging` added.
    ///
    /// An ``unnamed(status:message:)`` answer is transient whatever its status, since a gateway's 401 is not the
    /// server's word on the key.
    public var isTransient: Bool {
        switch self {
        case .network, .noConnection, .io, .storageFull, .rateLimited, .unnamed, .keyChanging: true
        case .server(let status, _, _): status >= 500 || status == 408
        default: false
        }
    }

    /// Fit to show a person.
    public var message: String {
        switch self {
        case .notFound(_, let message), .unauthorized(_, let message), .forbidden(_, let message),
            .validation(_, let message), .unknownType(let message), .rateLimited(_, let message, _),
            .server(_, _, let message), .io(let message), .network(let message), .unnamed(_, let message),
            .decoding(let message),
            .store(let message), .storageFull(let message), .signedOut(_, let message),
            .noKeychain(let message), .redirected(_, _, _, let message),
            .noServer(let message), .noCursor(let message), .hydrationIncomplete(let message), .noCatalog(let message),
            .wrongSchema(_, _, _, let message), .readingHandle(let message), .unsentDiffers(_, _, _, let message),
            .copyExpired(_, let message),
            .streamIncomplete(_, let message), .wrongServer(_, _, let message), .bytesAbsent(_, _, let message),
            .noRoom(_, _, _, let message),
            .contractMismatch(_, _, _, _, let message), .canceled(let message), .firstSyncWaiting(let message),
            .invalid(let message), .keyChanging(let message), .versionConflict(let message),
            .instanceChanged(let message), .closed(let message), .noConnection(let message):
            message
        }
    }

    /// The canonical error name shared with the core and CLI.
    ///
    /// Associated `code` values remain the server's refusal codes.
    public func code() -> String {
        let core: MarfaCore.MarfaError
        switch self {
        case .notFound(let code, let message): core = .NotFound(code: code, message: message)
        case .unauthorized(let code, let message): core = .Unauthorized(code: code, message: message)
        case .forbidden(let code, let message): core = .Forbidden(code: code, message: message)
        case .validation(let code, let message): core = .Validation(code: code, message: message)
        case .unknownType(let message): core = .UnknownType(message: message)
        case .rateLimited(let code, let message, let retryAfterSeconds):
            core = .RateLimited(code: code, message: message, retryAfterSeconds: retryAfterSeconds)
        case .server(let status, let code, let message): core = .Server(status: status, code: code, message: message)
        case .io(let message): core = .Io(message: message)
        case .network(let message): core = .Network(message: message)
        case .unnamed(let status, let message): core = .Unnamed(status: status, message: message)
        case .decoding(let message): core = .Decoding(message: message)
        case .store(let message): core = .Store(message: message)
        case .storageFull(let message): core = .StorageFull(message: message)
        case .signedOut(let origin, let message): core = .SignedOut(origin: origin, message: message)
        case .noKeychain(let message): core = .NoKeychain(message: message)
        case .redirected(let origin, let status, let location, let message):
            core = .Redirected(origin: origin, status: status, location: location, message: message)
        case .noServer(let message): core = .NoServer(message: message)
        case .noCursor(let message): core = .NoCursor(message: message)
        case .hydrationIncomplete(let message): core = .HydrationIncomplete(message: message)
        case .noCatalog(let message): core = .NoCatalog(message: message)
        case .wrongSchema(let path, let reason, let unsent, let message):
            core = .WrongSchema(path: path, reason: reason, unsent: unsent, message: message)
        case .readingHandle(let message): core = .ReadingHandle(message: message)
        case .unsentDiffers(let path, let unsent, let agreed, let message):
            core = .UnsentDiffers(path: path, unsent: unsent, agreed: agreed, message: message)
        case .copyExpired(let reason, let message): core = .CopyExpired(reason: reason, message: message)
        case .streamIncomplete(let reason, let message): core = .StreamIncomplete(reason: reason, message: message)
        case .wrongServer(let expected, let got, let message):
            core = .WrongServer(expected: expected, got: got, message: message)
        case .bytesAbsent(let hash, let reason, let message):
            core = .BytesAbsent(hash: hash, reason: reason, message: message)
        case .noRoom(let hash, let size, let free, let message):
            core = .NoRoom(hash: hash, size: size, free: free, message: message)
        case .contractMismatch(let served, let expected, let status, let writeSent, let message):
            core = .ContractMismatch(
                served: served, expected: expected, status: status, writeSent: writeSent, message: message)
        case .canceled(let message): core = .Canceled(message: message)
        case .firstSyncWaiting(let message): core = .FirstSyncWaiting(message: message)
        case .invalid(let message): core = .Invalid(message: message)
        case .versionConflict(let message): core = .Server(status: 409, code: "version_conflict", message: message)
        case .instanceChanged(let message): core = .CopyExpired(reason: "instance_changed", message: message)
        case .keyChanging: return "key_changing"
        case .closed: return "closed"
        case .noConnection: return "no_connection"
        }
        return core.code()
    }

    public var errorDescription: String? { message }

    init(_ error: MarfaCore.MarfaError) {
        switch error {
        case .NotFound(let code, let message): self = .notFound(code: code, message: message)
        case .Unauthorized(let code, let message): self = .unauthorized(code: code, message: message)
        case .Forbidden(let code, let message): self = .forbidden(code: code, message: message)
        case .Validation(let code, let message): self = .validation(code: code, message: message)
        case .UnknownType(let message): self = .unknownType(message: message)
        case .RateLimited(let code, let message, let retryAfterSeconds):
            self = .rateLimited(code: code, message: message, retryAfterSeconds: retryAfterSeconds)
        case .Server(409, "version_conflict", let message): self = .versionConflict(message: message)
        case .Server(409, "instance_changed", let message): self = .instanceChanged(message: message)
        case .Server(let status, let code, let message): self = .server(status: status, code: code, message: message)
        case .Io(let message): self = .io(message: message)
        case .Network(let message): self = .network(message: message)
        case .Unnamed(let status, let message): self = .unnamed(status: status, message: message)
        case .Decoding(let message): self = .decoding(message: message)
        case .Store(let message): self = .store(message: message)
        case .StorageFull(let message): self = .storageFull(message: message)
        case .SignedOut(let origin, let message): self = .signedOut(origin: origin, message: message)
        case .NoKeychain(let message): self = .noKeychain(message: message)
        case .Redirected(let origin, let status, let location, let message):
            self = .redirected(origin: origin, status: status, location: location, message: message)
        case .NoServer(let message): self = .noServer(message: message)
        case .NoCursor(let message): self = .noCursor(message: message)
        case .HydrationIncomplete(let message): self = .hydrationIncomplete(message: message)
        case .NoCatalog(let message): self = .noCatalog(message: message)
        case .WrongSchema(let path, let reason, let unsent, let message):
            self = .wrongSchema(path: path, reason: reason, unsent: unsent, message: message)
        case .ReadingHandle(let message): self = .readingHandle(message: message)
        case .UnsentDiffers(let path, let unsent, let agreed, let message):
            self = .unsentDiffers(path: path, unsent: unsent, agreed: agreed, message: message)
        case .CopyExpired("instance_changed", let message): self = .instanceChanged(message: message)
        case .CopyExpired(let reason, let message): self = .copyExpired(reason: reason, message: message)
        case .StreamIncomplete(let reason, let message): self = .streamIncomplete(reason: reason, message: message)
        case .WrongServer(let expected, let got, let message):
            self = .wrongServer(expected: expected, got: got, message: message)
        case .BytesAbsent(let hash, let reason, let message):
            self = .bytesAbsent(hash: hash, reason: reason, message: message)
        case .NoRoom(let hash, let size, let free, let message):
            self = .noRoom(hash: hash, size: size, free: free, message: message)
        case .ContractMismatch(let served, let expected, let status, let writeSent, let message):
            self = .contractMismatch(
                served: served, expected: expected, status: status, writeSent: writeSent, message: message)
        case .Canceled(let message): self = .canceled(message: message)
        case .FirstSyncWaiting(let message): self = .firstSyncWaiting(message: message)
        case .Invalid(let message): self = .invalid(message: message)
        }
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
/// A move is refused `MarfaError.validation` before anything is queued, with
/// the code `validation_error` where the edge's type lets the end that stays
/// hold more than one edge, such as `about`, and with the code `edge_cycle`
/// where the move would leave the edge running from an item to itself. A
/// move the copy cannot judge, such as one that closes a longer cycle, is
/// queued and refused by the server, and its verdict says why.
///
/// Once the server accepts a source move, the copy expires. The drain sends
/// the writes queued behind the move first, then throws
/// `MarfaError.copyExpired` with the reason `reach_changed` once, after
/// the last. The writes are answered, and the app hydrates again. A drain
/// that ends with a wait, an unreachable server, a stopped credential or a
/// write left undelivered returns its report instead, and the next call
/// throws `copyExpired`. A target move does not expire the copy.
public struct EdgeEdit: Sendable, Hashable {
    /// The end of an edge to move, and the item to move it to.
    public enum Move: Sendable, Hashable {
        case source(String)
        case target(String)
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
        let moves: MarfaCore.EdgeMove? =
            switch move {
            case .source(let id): MarfaCore.EdgeMove(end: .source, to: id)
            case .target(let id): MarfaCore.EdgeMove(end: .target, to: id)
            case nil: nil
            }
        return MarfaCore.EdgeEdit(properties: properties.core, baseVersion: baseVersion, moves: moves)
    }
}
