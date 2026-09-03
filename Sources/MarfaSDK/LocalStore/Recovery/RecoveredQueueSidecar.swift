import Foundation

/// The salvaged queue, as it is written to disk.
///
/// Plain JSON with no SDK types in it, because the whole point is that it
/// outlives the build that wrote it: an app reading this file may be a version
/// behind or ahead, and may not be a Swift app at all. `format` is what tells
/// a reader whether it understands the rest.
///
/// The row shapes are the store's own columns mapped back to the SDK's
/// property names — see ``QuarantinedStoreReader``. A blob's bytes are not
/// here; they are in the quarantined store beside this file.
struct RecoveredQueueSidecar: Codable {
    /// Bumped only when a reader that understands the current file would
    /// misread the new one.
    static let currentFormat = 1

    let format: Int
    let recordedAt: String
    let cause: String
    let reason: String

    /// Where the store was, and where it went. Both absolute, because the
    /// person reading this is looking for the file.
    let storePath: String
    let quarantinedStorePath: String

    /// Files that were beside the store and could not be moved with it. Empty
    /// on the ordinary path; a name here is data that was left behind.
    let unmovedSiblings: [String]

    let pendingMutations: [[String: JSONValue]]
    let droppedMutations: [[String: JSONValue]]
    let syncState: [[String: JSONValue]]
    let pendingBlobs: [[String: JSONValue]]

    static let fileName = "recovered-queue.json"
}

extension RecoveredQueueSidecar {
    init(
        cause: StoreRecovery.Cause,
        reason: String,
        storePath: String,
        quarantinedStorePath: String,
        unmovedSiblings: [String],
        recordedAt: Date,
        extraction: QuarantinedStoreReader.Extraction
    ) {
        self.format = Self.currentFormat
        self.recordedAt = recordedAt.ISO8601Format(.init(includingFractionalSeconds: true))
        self.cause = cause.rawValue
        self.reason = reason
        self.storePath = storePath
        self.quarantinedStorePath = quarantinedStorePath
        self.unmovedSiblings = unmovedSiblings
        self.pendingMutations = extraction.rows("pendingMutations")
        self.droppedMutations = extraction.rows("droppedMutations")
        self.syncState = extraction.rows("syncState")
        self.pendingBlobs = extraction.rows("pendingBlobs")
    }

    /// The event cursor the old store had reached, if it recorded one.
    var cursor: String? {
        syncState
            .first { $0["key"]?.stringValue == "last_event_id" }?["value"]?
            .stringValue
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        // Sorted and indented: this file is read by a person before it is read
        // by anything else, and a stable key order makes two incidents
        // comparable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
