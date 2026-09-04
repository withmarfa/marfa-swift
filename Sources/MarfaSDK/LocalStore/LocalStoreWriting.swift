import Foundation

/// One unsent write this device holds against an item, in the form the store
/// needs in order to put it back on top of the row the server sent.
///
/// The queue stores mutations as JSON keyed by ``MutationKind``, which is the
/// shape a replay needs: it has to reissue the caller's own call. Rebasing
/// needs the other shape — what the write does to a row — so the two are kept
/// apart rather than having the store learn to read the queue's payloads.
public enum PendingItemEdit: Sendable, Equatable {

    /// A partial-merge property delta, plus the two axes `PATCH /items/:id`
    /// carries beside it. Mirrors ``LocalStore/updateItem(id:properties:tier:)``:
    /// keys in the delta win, keys absent from it survive.
    case properties(delta: [String: JSONValue], tier: Tier?, sourceId: String?)

    /// A lifecycle move — a trash, a restore, or an explicit transition.
    case state(ItemState)
}

/// The writes ``SyncEngine`` performs against the device's local store.
///
/// The engine depends on this rather than on the concrete ``LocalStore`` for
/// the same reason it depends on ``Transport`` rather than on
/// `URLSessionTransport`: a sync cycle has two halves that can fail — what the
/// server sent, and what the device managed to store — and only one of them
/// was substitutable. SwiftData accepts every write the engine can construct,
/// so without a seam here the store-side failure is unreachable from a test
/// and the engine's behavior around it cannot be pinned down.
///
/// Named for the capability because ``LocalStore`` already names the actor
/// that provides it.
///
/// Every requirement is `async`, which is what lets an actor conform with its
/// ordinary isolated methods: the witness is called across the isolation
/// boundary. The protocol refines `Sendable` because the engine stores a
/// conformer and calls it from its own executor.
public protocol LocalStoreWriting: Sendable {

    /// Inserts an item, or updates the stored row when one already exists.
    func upsertItem(_ item: Item) async throws

    /// Stores what an app should see for an item the server just described:
    /// the server's row, with this device's own unsent writes put back on top
    /// of it.
    ///
    /// Returns `false` when the frame was refused for describing a server
    /// version the row has already passed.
    ///
    /// The read, the rebase and the write happen in one hop on purpose. Split
    /// across three, a write landing between the read and the write is lost
    /// with nothing reporting it.
    @discardableResult
    func applyServerItem(_ item: Item, rebasing edits: [PendingItemEdit]) async throws -> Bool

    /// Removes every stored item whose id is absent from `keeping`, except the
    /// ids in `protecting`. Returns the ids removed.
    ///
    /// The caller has to have seen the whole server side before asking: a row
    /// is removed because the server did not mention it, and a partial answer
    /// mentions nothing about the pages it did not reach.
    @discardableResult
    func pruneItems(keeping: Set<String>, protecting: Set<String>) async throws -> [String]

    /// Inserts an edge, or updates the stored row when one already exists.
    func upsertEdge(_ edge: Edge) async throws

    /// Removes an edge. Idempotent — deleting an absent edge is a no-op.
    func deleteEdge(id: String) async throws

    /// Stores the metadata row the server sent, replacing the local one.
    func upsertMetadata(_ metadata: Metadata) async throws

    /// Permanently removes an item. Idempotent — purging an absent item is a
    /// no-op.
    func purgeItem(id: String) async throws
}

extension LocalStore: LocalStoreWriting {}
