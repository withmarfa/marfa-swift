import Foundation
import Observation

// MARK: - BlobUploadState

/// Lifecycle state of an in-flight blob upload, as observed by
/// ``BlobUploadProgressQuery``.
///
/// Transitions:
///
/// - `.pending` is the placeholder before a ``SyncEvent/blobUploadStarted``
///   has been observed for a hash. Currently unused internally — the
///   query creates entries only on `started` — but kept public so
///   consumers can represent their own queued-but-not-started state
///   if they wire in app-layer pre-upload events.
/// - `.uploading(bytesUploaded:totalBytes:)` — between
///   ``SyncEvent/blobUploadStarted`` and the terminal event.
/// - `.completed` — the upload finished. Evicted from the query's
///   `uploads` dict immediately; consumers wanting a "recently
///   completed" affordance should layer it on top.
/// - `.failed(MymeError)` — a transient or permanent failure. On
///   transient failures a new `.uploading(...)` will follow when the
///   next replay cycle fires; on permanent failure the
///   ``SyncEvent/mutationDropped`` event is the companion signal.
public enum BlobUploadState: Sendable, Equatable {
    case pending
    case uploading(bytesUploaded: Int64, totalBytes: Int64)
    case completed
    case failed(MymeError)

    public static func == (lhs: BlobUploadState, rhs: BlobUploadState) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.completed, .completed): return true
        case let (.uploading(a, b), .uploading(c, d)):
            return a == c && b == d
        case let (.failed(a), .failed(b)):
            return a.code == b.code && a.status == b.status && a.message == b.message
        default:
            return false
        }
    }
}

// MARK: - BlobUploadProgress

/// Per-upload snapshot tracked by ``BlobUploadProgressQuery``.
public struct BlobUploadProgress: Sendable, Identifiable, Equatable {
    public var id: String { hash }

    /// SHA-256 content hash — matches the hash passed to
    /// ``BlobsNamespace/upload(data:mimeType:)`` and the one returned
    /// in ``BlobUploadResponse``.
    public let hash: String

    /// Total bytes the upload expects to transfer. `0` before the
    /// first progress event has a reliable total.
    public let totalBytes: Int64

    /// Bytes uploaded so far. Monotonically non-decreasing within a
    /// single attempt; resets to `0` on retry after a transient fail.
    public let bytesUploaded: Int64

    /// Current state — see ``BlobUploadState``.
    public let state: BlobUploadState

    public init(
        hash: String,
        totalBytes: Int64,
        bytesUploaded: Int64,
        state: BlobUploadState
    ) {
        self.hash = hash
        self.totalBytes = totalBytes
        self.bytesUploaded = bytesUploaded
        self.state = state
    }
}

// MARK: - BlobUploadProgressQuery

/// A live, observable projection of the sync engine's blob-upload
/// events.
///
/// Subscribes to ``SyncEngine/events`` and maintains an
/// `uploads: [hash: BlobUploadProgress]` dict keyed by content hash.
/// Consumers render directly from the dict — iterate over `uploads`
/// for a global activity HUD, or look up a specific hash for a per-
/// attachment progress bar.
///
/// On ``SyncEvent/blobUploadCompleted`` the entry is evicted from the
/// dict (evict-on-complete semantics). Apps that want a "recently
/// completed" fade should snapshot the final value in their own view
/// layer before the entry disappears.
///
/// Vended by ``MymeStore/queryBlobUploadProgress(engine:)``; returns
/// `nil` for network-only clients without a sync engine.
@Observable
@MainActor
public final class BlobUploadProgressQuery {

    // MARK: - Published state

    /// Per-hash progress entries. Present for every started-but-not-
    /// completed upload. Evicted on ``SyncEvent/blobUploadCompleted``.
    public private(set) var uploads: [String: BlobUploadProgress] = [:]

    // MARK: - Internals

    private var listenerTask: Task<Void, Never>?

    // MARK: - Init

    init(engine: SyncEngine) {
        let stream = engine.events
        self.listenerTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self else { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: SyncEvent) {
        switch event {
        case let .blobUploadStarted(hash, totalBytes):
            uploads[hash] = BlobUploadProgress(
                hash: hash,
                totalBytes: totalBytes,
                bytesUploaded: 0,
                state: .uploading(bytesUploaded: 0, totalBytes: totalBytes)
            )
        case let .blobUploadProgress(hash, sent, total):
            // Only update progress for entries that are still tracked.
            // The engine spawns progress emissions as detached Tasks
            // (the URLSession progress callback isn't actor-isolated),
            // and on slow hardware they can race the synchronously-
            // emitted `.blobUploadCompleted` and arrive after eviction.
            // Without this guard a final progress tick (e.g. 100/100)
            // resurrects the entry as `.uploading(4, 4)` and never
            // evicts. Once `.blobUploadCompleted` fires, the upload is
            // terminal — late progress is noise.
            guard uploads[hash] != nil else { break }
            uploads[hash] = BlobUploadProgress(
                hash: hash,
                totalBytes: total,
                bytesUploaded: sent,
                state: .uploading(bytesUploaded: sent, totalBytes: total)
            )
        case let .blobUploadCompleted(hash):
            // Evict-on-complete — keeps the dict tight and matches
            // "raw state; apps layer UX on top" intent.
            uploads[hash] = nil
        case let .blobUploadFailed(hash, error):
            // Retain the failure entry so consumers can render a
            // red badge or a retry button. A subsequent
            // `blobUploadStarted` for the same hash (transient retry)
            // overwrites the entry with a fresh `.uploading(0, total)`.
            let previous = uploads[hash]
            uploads[hash] = BlobUploadProgress(
                hash: hash,
                totalBytes: previous?.totalBytes ?? 0,
                bytesUploaded: previous?.bytesUploaded ?? 0,
                state: .failed(error)
            )
        default:
            break
        }
    }

    // MARK: - Lifecycle

    /// Stops listening to the engine's event stream. After calling
    /// `stop()`, `uploads` will no longer update.
    public func stop() {
        listenerTask?.cancel()
        listenerTask = nil
    }
}
