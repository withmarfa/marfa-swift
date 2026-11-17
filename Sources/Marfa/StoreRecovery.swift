import Foundation
internal import MarfaCore

/// A write the server has not taken, read from a store that ``WorkingCopy/open(store:server:fileBudget:ifRefused:)``
/// refused, so a person can see what a removal would lose.
public struct UnsentWrite: Sendable, Hashable {
    public var id: String
    /// The kind as the store names it, which may be one this build does not send.
    public var kind: String
    public var itemId: String?
    /// The body the write sends, as the store holds it.
    public var body: String
    /// The verdict the store recorded, including a value this build does not recognize.
    public var verdict: String?

    public init(id: String, kind: String, itemId: String? = nil, body: String, verdict: String? = nil) {
        self.id = id
        self.kind = kind
        self.itemId = itemId
        self.body = body
        self.verdict = verdict
    }

    init(_ core: MarfaCore.UnsentWrite) {
        self.init(id: core.id, kind: core.kind, itemId: core.itemId, body: core.body, verdict: core.verdict)
    }
}

/// What ``WorkingCopy/setAsideDamaged(store:)`` did.
public struct SetAside: Sendable, Hashable {
    /// Where the damaged store now is, with its logs beside it.
    public var setAside: String
    /// The writes the new store holds that the server has not taken.
    public var carried: UInt64
    /// The writes found in the old queue that could not be read.
    public var unread: UInt64
    /// The id of each unread write whose id could be read.
    public var unreadIds: [String]
    /// Whether the old queue was read whole.
    ///
    /// That is every write it holds found, and every record that decides how a carried write is sent read. Where not, the store set aside may hold more, and every file the cache held stays until that store
    /// is removed or moved from where the set-aside put it.
    public var whole: Bool
    /// The carried writes held blocked ``BlockedReason/instanceChanged``.
    ///
    /// The old store did not say which instance it was built from. Release one to send it to the instance the new store is hydrated from.
    public var held: UInt64
    /// The carried writes held blocked ``BlockedReason/recordUnread``.
    ///
    /// A record that decides how each is sent could not be read. Release one to send it without that record.
    public var recordUnread: UInt64

    public init(
        setAside: String, carried: UInt64, unread: UInt64, unreadIds: [String], whole: Bool, held: UInt64,
        recordUnread: UInt64
    ) {
        self.setAside = setAside
        self.carried = carried
        self.unread = unread
        self.unreadIds = unreadIds
        self.whole = whole
        self.held = held
        self.recordUnread = recordUnread
    }

    init(_ core: MarfaCore.SetAside) {
        self.init(
            setAside: core.setAside, carried: core.carried, unread: core.unread, unreadIds: core.unreadIds,
            whole: core.whole, held: core.held, recordUnread: core.recordUnread)
    }
}

/// A store the working copy refuses to open: what it holds, and how to give it up or keep what can be kept.
///
/// ``WorkingCopy/open(store:server:fileBudget:ifRefused:)`` refuses a store SQLite cannot read with
/// ``MarfaError/storeDamaged(path:reason:unsent:message:)`` and one another build made with
/// ``MarfaError/wrongSchema(path:reason:unsent:message:)``. Each carries the count of writes the server has not
/// taken. ``unsentWrites(in:)`` lists them, so a person sees what a removal loses before agreeing to it. Close every
/// copy of the store in this process first, for each call here.
extension WorkingCopy {
    /// Reads every page of the store at `store` and checks each index against its rows, changing nothing.
    ///
    /// Throws ``MarfaError/storeDamaged(path:reason:unsent:message:)``, naming the store and counting its unsent
    /// writes, where SQLite cannot read it, ``MarfaError/wrongSchema(path:reason:unsent:message:)`` where another
    /// build made it, and ``MarfaError/readingHandle(message:)`` while another process writes it. A damaged store
    /// met part way through a call is refused with an empty path; this names it. It reads the whole file, so it
    /// takes longer the larger the store is.
    public static func check(store: URL) async throws {
        let path = store.path
        try await background { try checkStore(path: path) }
    }

    /// The writes the server has not taken that the store at `store` holds, whether the store is damaged, made by
    /// another build, or whole.
    ///
    /// A kind or a verdict is as the store names it, which may be one this build does not know.
    public static func unsentWrites(in store: URL) async throws -> [UnsentWrite] {
        let path = store.path
        return try await background { try readUnsent(path: path).map(UnsentWrite.init) }
    }

    /// Keeps the damaged store at `store` beside itself and makes a new store at `store` that carries every write the
    /// damaged queue lets be read.
    ///
    /// The old store and its logs move to `<store>.damaged-<n>`, never deleted. The new store holds no copy:
    /// hydrate it, then drain, to send what it carries. A carried write may be blocked
    /// ``BlockedReason/instanceChanged`` or ``BlockedReason/recordUnread`` until released, which the result counts.
    /// Throws `invalid` for a store that opens as it is or a folder's store,
    /// ``MarfaError/wrongSchema(path:reason:unsent:message:)`` for a store another build made, and `readingHandle`
    /// while another process writes it. A set-aside that stopped part way is finished by calling again.
    public static func setAsideDamaged(store: URL) async throws -> SetAside {
        let path = store.path
        return try await background { SetAside(try MarfaCore.setAsideDamaged(path: path)) }
    }

    /// Removes the store at `store` as ``remove(store:unsent:)`` does, agreeing to lose every write it holds that the
    /// server has not taken, however many there are and whether or not they can be counted.
    ///
    /// It is for a store `open` refuses with ``MarfaError/storeDamaged(path:reason:unsent:message:)``, whose
    /// queue cannot always be counted. Show the person ``unsentWrites(in:)`` first. Throws as `remove` does, except
    /// for the count.
    public static func removeLosingAll(store: URL) async throws {
        let path = store.path
        try await background { try removeStoreLosingAll(path: path) }
    }
}
