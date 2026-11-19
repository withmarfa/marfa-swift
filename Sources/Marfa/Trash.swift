import Foundation
internal import MarfaCore

/// What trashing several items would take, as the server read it.
///
/// Get one from ``Items/previewTrash(ids:)``, show the person what it takes, and pass it unchanged to
/// ``Items/trash(_:)``. It carries an opaque digest that binds the trash to the state the server previewed, so a
/// preview cannot be made or changed by an app.
public struct TrashPreview: Sendable, Hashable {
    /// What the trash takes with one named item.
    public struct Entry: Sendable, Hashable {
        /// The named item's ID.
        public let id: String
        /// The named item's type.
        public let type: String
        /// The version the server read the item at.
        public let version: Int64
        /// Items the key can read that the trash takes with this item.
        ///
        /// Leaves first, at most 100, and never the item itself.
        public let takes: [Taken]
        /// How many items the key can read that the trash takes for this one, the item itself included.
        public let count: UInt64
        /// `takes` was cut at its limit, so it lists only part of what the trash takes.
        public let truncated: Bool
    }

    /// An item the trash takes with a named one.
    public struct Taken: Sendable, Hashable {
        public let id: String
        public let type: String
        public let version: Int64
    }

    /// Each named item once, in the order named.
    public let items: [Entry]
    /// How many distinct items the key can read that the trash would take, including those taken with a named one.
    public let count: UInt64
    let digest: String

    init(_ core: MarfaCore.TrashPreview) {
        items = core.items.map { entry in
            Entry(
                id: entry.id, type: entry.type, version: entry.version,
                takes: entry.takes.map { Taken(id: $0.id, type: $0.type, version: $0.version) },
                count: entry.count, truncated: entry.truncated)
        }
        count = core.count
        digest = core.digest
    }

    var core: MarfaCore.TrashPreview {
        MarfaCore.TrashPreview(
            items: items.map { entry in
                MarfaCore.TrashPreviewItem(
                    id: entry.id, type: entry.type, version: entry.version,
                    takes: entry.takes.map { MarfaCore.TrashTaken(id: $0.id, type: $0.type, version: $0.version) },
                    count: entry.count, truncated: entry.truncated)
            },
            count: count, digest: digest)
    }
}

/// A trash the server accepted.
public struct TrashReport: Sendable, Hashable {
    /// The copy shows the trash: every item it holds that the trash took, listed or not, is in the bin, or as a later
    /// event left it.
    ///
    /// When `false`, the trash still happened. The copy has not caught up yet, `behind` says why, and the follow or
    /// the next catch-up settles it.
    public let settled: Bool
    /// Why the copy has not caught up yet, where ``settled`` is `false`.
    public let behind: String?

    init(_ core: MarfaCore.TrashReport) {
        settled = core.settled
        behind = core.behind
    }
}

extension Items {
    /// Reads what trashing `ids` would take: each item once, what its trash takes with it, and a count.
    ///
    /// Names 1 to 20 distinct items; an ID named twice counts once. None, or more than 20, throws `validation` with the
    /// code `validation_error` before anything is sent. It needs the server and reads online: offline it throws
    /// `network`, and a copy with no server throws `noServer`. A reading handle may call it. Show the person
    /// ``TrashPreview/items`` and ``TrashPreview/count``, then pass the preview unchanged to ``trash(_:)``.
    ///
    /// A preview is never queued and an offline app has no preview: it queues one ``delete(_:)`` for each item
    /// instead.
    public func previewTrash(ids: [String]) async throws -> TrashPreview {
        try await holder.runBlocking { core in TrashPreview(try core.previewTrash(ids: ids)) }
    }

    /// Moves the preview's named items and everything their trash takes to the bin on the server now, all or none.
    ///
    /// Never queued: it needs the server, and an offline app uses the single queued ``delete(_:)`` for each item
    /// instead. The key needs write on each named item's type. A cascade can also take items the key cannot read;
    /// the preview lists and counts only items it can read.
    ///
    /// Refused before anything is sent, with the copy and the queue as they were:
    ///
    /// - `invalid` while a write to a named or taken item waits, a create that names such an item's `source_id`
    ///   included. Where a preview cut `takes`, a waiting write to any item refuses the trash. Its message names,
    ///   for each waiting write, the commands that take it out of its wait: ``Queue/drain()``, ``Queue/release(_:)``
    ///   or ``Queue/withdraw(_:)``. Clear them and trash again.
    /// - ``MarfaError/itemBeingRemoved(id:message:)`` while a trash or a purge already holds one of the items.
    /// - `readingHandle` for a copy that only reads, and `noServer` for a copy with no server.
    ///
    /// The server refuses a trash with ``MarfaError/trashPlanChanged(message:server:)`` when an item or what it
    /// takes changed since the preview, and changes nothing: preview again and ask the person again.
    ///
    /// Until the call returns, a write to a named or taken item throws ``MarfaError/itemBeingRemoved(id:message:)``,
    /// and none is queued. A `network` failure after the request went out may follow a trash the server made. Its
    /// events settle the copy, so preview again before trashing again.
    ///
    /// Once the server accepts, the call waits up to five seconds for the copy to take the server's events through
    /// the trash. ``TrashReport/settled`` says whether it did. When it is `false` the trash still happened, and the
    /// copy shows it once the follow or the next catch-up has run.
    public func trash(_ preview: TrashPreview) async throws -> TrashReport {
        let report = try await holder.runBlocking { core in TrashReport(try core.trashItems(preview: preview.core)) }
        feed.announce(Change(origin: .refreshed(.trashed), itemId: nil, edgeId: nil))
        return report
    }
}
