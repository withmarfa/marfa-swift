import Foundation

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

    /// Inserts an edge, or updates the stored row when one already exists.
    func upsertEdge(_ edge: Edge) async throws

    /// Removes an edge. Idempotent — deleting an absent edge is a no-op.
    func deleteEdge(id: String) async throws

    /// Replaces an item's metadata and returns what was stored.
    func setMetadata(itemId: String, input: MetadataInput) async throws -> Metadata

    /// Permanently removes an item. Idempotent — purging an absent item is a
    /// no-op.
    func purgeItem(id: String) async throws
}

extension LocalStore: LocalStoreWriting {}
