import Foundation
import SwiftData

/// What happened to a store the running build could not open.
///
/// Non-`nil` on ``StoreOpenResult/recovery`` only when the fail-safe ran, which
/// is rare and always worth telling a person about: the device is now looking
/// at an empty store, and everything the server does not hold a copy of has
/// moved to the quarantine directory named here.
///
/// The four things that only lived in the old store are the queued writes, the
/// bytes behind a queued upload, the log of writes the server refused, and the
/// cursor saying which events this device had already seen. The counts below
/// say how much of each was salvaged.
public struct StoreRecovery: Sendable, Hashable {

    /// Why the store was set aside.
    public enum Cause: String, Sendable, Hashable, Codable {
        /// The container refused to attach to the store. Ordinarily this means
        /// the store's entity shapes match no version the running build knows,
        /// which is what an upgrade past a missing migration looks like.
        case unreadable

        /// The store records a schema version this build does not have, so a
        /// newer build wrote it. Refused before any attempt to open it: a
        /// build that migrated it forward would be guessing at a shape it has
        /// never been told about.
        case newerThanCode
    }

    public let cause: Cause

    /// One sentence saying what refused and why, for a log or an alert. The
    /// underlying error's description for ``Cause/unreadable``; the two
    /// versions compared for ``Cause/newerThanCode``.
    public let reason: String

    /// The directory the old store was moved into, holding the database file
    /// and everything SQLite and Core Data keep beside it. Nothing removes it
    /// — an app that has finished with it deletes it.
    public let quarantineDirectory: URL

    /// The JSON file inside ``quarantineDirectory`` holding the salvaged
    /// queue, or `nil` when nothing could be read out of the quarantined
    /// store. The bytes themselves stay in the quarantined database.
    public let sidecar: URL?

    /// Why the salvage produced no sidecar, when it did not. `nil` on the
    /// ordinary path.
    public let sidecarError: String?

    /// Queued writes recovered into the sidecar.
    public let pendingMutationCount: Int

    /// Dead-letter rows recovered into the sidecar.
    public let droppedMutationCount: Int

    /// Queued blob uploads recovered into the sidecar. Their bytes are not in
    /// the sidecar — they are still in the quarantined store, which is the
    /// reason it is quarantined rather than deleted.
    public let pendingBlobCount: Int

    /// The event cursor the old store had reached, when one was recorded.
    public let cursor: String?

    public init(
        cause: Cause,
        reason: String,
        quarantineDirectory: URL,
        sidecar: URL?,
        sidecarError: String?,
        pendingMutationCount: Int,
        droppedMutationCount: Int,
        pendingBlobCount: Int,
        cursor: String?
    ) {
        self.cause = cause
        self.reason = reason
        self.quarantineDirectory = quarantineDirectory
        self.sidecar = sidecar
        self.sidecarError = sidecarError
        self.pendingMutationCount = pendingMutationCount
        self.droppedMutationCount = droppedMutationCount
        self.pendingBlobCount = pendingBlobCount
        self.cursor = cursor
    }
}

/// A store, and what it took to get one.
///
/// ``MarfaModelContainer/make(path:cloudKitDatabase:)`` returns the container
/// alone and is the right call when a consumer has nothing to do with the
/// answer. Use ``MarfaModelContainer/open(path:cloudKitDatabase:)`` when
/// something in the app should react to a store that had to be rebuilt.
public struct StoreOpenResult: Sendable {
    public let container: ModelContainer

    /// Non-`nil` when the fail-safe ran. `nil` on every ordinary open,
    /// including one that migrated the store forward.
    public let recovery: StoreRecovery?
}
