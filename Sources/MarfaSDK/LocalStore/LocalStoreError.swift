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

    /// A model fetch returned no rows for a key the caller treated as
    /// known (e.g. an upsert tried to mutate a row mid-transaction and
    /// found it gone). Carries the missing id.
    case modelMissing(id: String)
}
