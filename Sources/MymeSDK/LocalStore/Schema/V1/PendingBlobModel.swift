import Foundation
import SwiftData

/// Binary upload buffer for queued blob uploads.
///
/// Decoupled from `PendingMutationModel` so that `payloadJson` stays lean
/// and one blob (keyed by SHA-256 hash) can back many `uploadBlob`
/// mutations. Atomicity at enqueue time is preserved by writing the blob
/// row and the mutation row in a single `ModelContext.save()`.
///
/// `data` carries `@Attribute(.externalStorage)` so SwiftData stores
/// large blob bytes in a sibling file rather than inline in the main
/// SQLite row. The hint is honoured at SwiftData's discretion (it's
/// documented as a suggestion, not a guarantee) but is the right
/// hint to give for multi-MB image / video uploads.
@Model
final class PendingBlobModel {
    /// `"sha256:hex"` content address. Logical key.
    var hash: String = ""

    @Attribute(.externalStorage) var data: Data = Data()

    var mimeType: String = ""

    init() {}

    // MARK: - Indexes

    #Index<PendingBlobModel>([\.hash])
}
