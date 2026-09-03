import Foundation

/// Errors thrown by ``LocalStore`` and ``MutationQueue`` operations that
/// don't fit the public ``MarfaError`` hierarchy.
///
/// `MarfaError` and its subclasses model server- and transport-shaped errors;
/// these cases cover storage-layer mishaps that the consumer can't address
/// through the API surface (the database file is unwritable, a JSON column
/// failed to encode, etc.).
public enum LocalStoreError: Error, Sendable {
    /// JSON encoding failed for a payload column. The associated string
    /// names the column or operation that failed for diagnostic logging.
    case encodingFailure(String)

    /// The underlying SwiftData container could not be opened or migrated.
    /// Carries the originating error's localized description.
    case databaseSetupFailed(String)

    /// A store this build cannot open also could not be moved aside, so
    /// nothing was deleted and no container was built. Carries what failed.
    ///
    /// The alternative — rebuilding anyway — is what this case exists to stop.
    /// It would take the queued writes, the dead-letter log, the event cursor
    /// and the bytes behind every queued upload with it, and the app would
    /// have no way to know that had happened.
    case storeQuarantineFailed(String)

    /// A model fetch returned no rows for a key the caller treated as
    /// known (e.g. an upsert tried to mutate a row mid-transaction and
    /// found it gone). Carries the missing id.
    case modelMissing(id: String)
}
