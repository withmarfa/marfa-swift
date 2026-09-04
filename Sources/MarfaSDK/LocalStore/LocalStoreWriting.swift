import Foundation

/// One unsent write this device holds against an item, in the form the store
/// needs in order to put it back on top of the row the server sent.
///
/// The queue stores mutations as JSON keyed by ``MutationKind``, which is the
/// shape a replay needs: it has to reissue the caller's own call. Rebasing
/// needs the other shape — what the write does to a row — so the two are kept
/// apart rather than having the store learn to read the queue's payloads.
public enum PendingItemEdit: Sendable, Equatable {

    /// A partial-merge property delta, plus the one axis `PATCH /items/:id`
    /// carries beside it that a local write also applies. Mirrors
    /// ``LocalStore/updateItem(id:properties:tier:)``: keys in the delta win,
    /// keys absent from it survive.
    ///
    /// `sourceId` is deliberately not here, though the same PATCH carries it.
    /// `updateItem` takes no such parameter, so a local edit never writes that
    /// column and the device shows the server's value until the queue drains.
    /// Rebasing it anyway would make the field change on the arrival of an
    /// inbound frame about something else entirely — visible only after an
    /// unrelated event, which is a worse thing to debug than a field that
    /// simply lags. The queue still replays the edit and the server still
    /// echoes it back; what is dropped is an optimistic preview no other code
    /// path offers.
    case properties(delta: [String: JSONValue], tier: Tier?)

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
    /// **The row's read, rebase and write are one hop on purpose**, so no other
    /// write to that row can land between the read and the write that follows
    /// it. Split across three calls, one that did would be overwritten with
    /// nothing reporting it.
    ///
    /// **That does not extend to `edits`, and the difference is worth stating
    /// where it will be read.** The caller gathers the queued writes in a
    /// separate call before this one, so the list is a snapshot taken slightly
    /// earlier rather than a view of the queue as of this hop. An edit enqueued
    /// in the gap is absent from `edits` and is not rebased, so the server's
    /// value for that field is what stays visible until the queue drains and
    /// the server echoes the edit back. The window is two awaits wide and the
    /// outcome is a stale field rather than a lost write — the queue still
    /// holds the edit and still replays it — but it is not the same guarantee
    /// as the one above and reading it as such is how the gap would be missed.
    /// Closing it needs the queue and the store to be read under one lock,
    /// which they do not share.
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
