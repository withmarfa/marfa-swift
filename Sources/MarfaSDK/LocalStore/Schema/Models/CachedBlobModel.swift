import Foundation
import SwiftData

/// Bytes this device has, so a blob it can already see does not need the
/// network to be seen again.
///
/// **Distinct from ``PendingBlobModel``, which is the outbound buffer.** That
/// one holds bytes on their way *to* the server and is deleted the moment
/// they arrive — which is the whole defect this table exists to close. A
/// person saved an image, watched it sync, and then could not open it on a
/// train, because the only copy the device had was the copy it deleted on
/// success. Every read went to the network for a file the device had held
/// minutes earlier.
///
/// So a successful upload now *moves* its bytes here rather than dropping
/// them, and a download writes through. `contentHash` is a content address,
/// so a row is immutable: same hash, same bytes, and a re-fetch can never
/// disagree with what is stored.
///
/// **A client with no server writes here too, and those rows are owned rather
/// than cached.** See ``isOwned``: there is nowhere else for those bytes to
/// be, so the eviction rule and the size bound both have to leave them alone.
///
/// `data` carries `@Attribute(.externalStorage)` for the reason
/// ``PendingBlobModel/data`` does — SwiftData keeps large payloads in a
/// sibling file rather than inline in the row.
@Model
final class CachedBlobModel {
    /// `"sha256:hex"` content address. Logical key, and named `contentHash`
    /// rather than `hash` for the reason ``PendingBlobModel`` names it that:
    /// every Swift type carries a `hash` method via `Hashable`, and the name
    /// conflict breaks SwiftData's metadata pipeline on save.
    var contentHash: String = ""

    @Attribute(.externalStorage) var data: Data = Data()

    var mimeType: String = ""

    /// Bytes held, kept as a column so eviction can total a store without
    /// loading every payload it is deciding whether to drop.
    var byteCount: Int = 0

    /// When this row was last served or written, ISO 8601 with fractional
    /// seconds. **Eviction is least-recently-used and this is the whole
    /// ordering**, so a read updates it: a file opened every day should
    /// outlive one fetched once and never opened again, and a
    /// write-time-only stamp gets that backwards.
    var lastUsedAt: String = ""

    /// Whether this device is the only thing holding these bytes.
    ///
    /// **Eviction skips an owned row, and the bound does not refuse one.**
    /// Everything else here is a second copy of something the server has, so
    /// dropping it costs a round trip and nothing more. Bytes written by a
    /// client with no server are not a copy of anything: evicting them, or
    /// silently declining to store one over the cache bound, loses the file.
    ///
    /// The name is about provenance rather than policy — `pinned` would say
    /// what happens and not why, and the next person to tune the eviction
    /// rule needs the why.
    var isOwned: Bool = false

    init() {}

    // MARK: - Indexes

    #Index<CachedBlobModel>([\.contentHash], [\.lastUsedAt])
}
