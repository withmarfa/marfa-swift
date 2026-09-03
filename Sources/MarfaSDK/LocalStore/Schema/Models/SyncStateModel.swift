import Foundation
import SwiftData

/// Key/value table for sync-engine cursor and bookkeeping state.
///
/// Two known keys today: `last_event_id` (the SSE cursor) and
/// `last_full_sync_at` (timestamp of the most recent initial-sync sweep).
///
/// Uniqueness on `key` is enforced via the upsert pattern (fetch-by-key,
/// update-or-insert). No `@Attribute(.unique)` — CloudKit silently refuses
/// uniqueness constraints.
@Model
final class SyncStateModel {
    var key: String = ""
    var value: String = ""

    init() {}

    // MARK: - Indexes

    #Index<SyncStateModel>([\.key])
}
