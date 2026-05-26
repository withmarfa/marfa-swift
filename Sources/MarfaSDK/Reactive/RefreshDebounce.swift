import Foundation

/// Coalescing window applied between a `ModelContext.didSave` notification
/// and the reactive query's refetch.
///
/// SwiftData fires `didSave` synchronously after every successful
/// `ModelContext.save()`. Bulk SSE catch-up regularly applies dozens of
/// upserts in tens of milliseconds; without coalescing each query would
/// re-fetch on every notification and burn the main actor for the duration
/// of the burst. A 50 ms window collapses bursts into a single fetch
/// without visible UI lag (≈ 3 frames at 60 Hz).
///
/// Defined as a single constant so a future profiling pass can tune the
/// value in one place — every reactive query reads from `interval`.
enum RefreshDebounce {
    /// Default debounce window between `didSave` and refetch.
    static let interval: Int = 50
}
