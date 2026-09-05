import Foundation
import SwiftData

extension LocalStore {
    /// How many bytes of cached blobs a store keeps before evicting.
    ///
    /// **A stated rule rather than a tuned number.** 256 MB is roughly what a
    /// photo-heavy library's recent working set costs and is small enough that
    /// a device never chooses between this cache and the person's own storage.
    /// What matters more than the figure is that there *is* one: an unbounded
    /// read-through cache is a slow disk leak that nobody attributes to the
    /// SDK, and a cache with no rule is one somebody eventually deletes
    /// wholesale.
    public static let defaultBlobCacheBytes = 256 * 1024 * 1024

    /// Puts bytes in the cache, or refreshes what is already there.
    ///
    /// A hash is a content address, so a row is immutable: the same hash means
    /// the same bytes and a second write only moves the row's place in the
    /// eviction order. That is why this cannot corrupt anything by racing
    /// itself — the worst two concurrent writers do is agree.
    /// The shape LocalStoreWriting requires. Kept beside the bounded one
    /// rather than defaulted on the protocol, for the reason written there.
    public func cacheBlob(hash: String, data: Data, mimeType: String) throws {
        try cacheBlob(hash: hash, data: data, mimeType: mimeType, limit: nil)
    }

    func cacheBlob(hash: String, data: Data, mimeType: String, limit: Int?) throws {
        let bound = limit ?? Self.defaultBlobCacheBytes
        // **A blob that cannot fit is not cached, rather than cached and then
        // evicting everything to make room it will not get.** Without this the
        // loop deletes every row including the one just written and keeps
        // nothing, so one large video flushes a person's whole cache for no
        // gain. The write is refused silently because a blob too big to keep
        // is not an error — the server still has it.
        guard data.count <= bound else { return }
        let stamped = now()
        let predicate = #Predicate<CachedBlobModel> { $0.contentHash == hash }
        var descriptor = FetchDescriptor<CachedBlobModel>(predicate: predicate)
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            // **The bytes are content-addressed; the MIME type is not.** It
            // comes from three authorities — the caller who uploaded, the
            // outbound row, and the server's `Content-Type` on a download —
            // and only the hash is guaranteed to agree between them. A first
            // version refreshed the stamp alone, so the first writer won for
            // ever and a later download could not correct it: one hash, two
            // answers, depending on whether this device's cache was warm.
            existing.mimeType = mimeType
            existing.lastUsedAt = stamped
        } else {
            let row = CachedBlobModel()
            row.contentHash = hash
            row.data = data
            row.mimeType = mimeType
            row.byteCount = data.count
            row.lastUsedAt = stamped
            modelContext.insert(row)
        }
        try modelContext.save()
        try evictBlobs(over: bound)
    }

    /// The bytes and MIME type this device holds for a hash, or `nil`.
    ///
    /// **Reading updates the row's place in the eviction order**, which is
    /// what makes the rule least-recently-*used* rather than
    /// least-recently-written. A file opened every day should outlive one
    /// fetched once and never opened again, and stamping only on write gets
    /// that exactly backwards.
    func cachedBlob(hash: String) throws -> (data: Data, mimeType: String)? {
        let predicate = #Predicate<CachedBlobModel> { $0.contentHash == hash }
        var descriptor = FetchDescriptor<CachedBlobModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first else { return nil }
        row.lastUsedAt = now()
        try modelContext.save()
        return (row.data, row.mimeType)
    }

    /// Drops the least recently used rows until the cache fits.
    ///
    /// **Totals the `byteCount` column rather than the payloads.** Loading
    /// every blob to decide which ones to unload is the shape that makes a
    /// cache worse than none, and it is why the count is stored beside the
    /// bytes rather than derived from them.
    ///
    /// `lastUsedAt` has millisecond resolution, so blobs touched inside one
    /// millisecond tie and their relative order is arbitrary. That is left
    /// alone rather than broken with a sequence column: rows used in the same
    /// millisecond *are* equally recent, so either choice is the right one,
    /// and the ordering only has to be right between rows a person could tell
    /// apart.
    @discardableResult
    func evictBlobs(over limit: Int) throws -> Int {
        let rows = try modelContext.fetch(
            FetchDescriptor<CachedBlobModel>(sortBy: [SortDescriptor(\.lastUsedAt, order: .forward)])
        )
        var total = rows.reduce(0) { $0 + $1.byteCount }
        var evicted = 0
        for row in rows where total > limit {
            total -= row.byteCount
            modelContext.delete(row)
            evicted += 1
        }
        if evicted > 0 { try modelContext.save() }
        return evicted
    }

    /// Bytes currently held, for a consumer that wants to show or bound it.
    func cachedBlobBytes() throws -> Int {
        try modelContext.fetch(FetchDescriptor<CachedBlobModel>())
            .reduce(0) { $0 + $1.byteCount }
    }
}

extension LocalStore {
    /// Backdates a cached blob's use stamp, so a test can state a recency
    /// relationship the wall clock cannot express at millisecond resolution.
    /// Nothing in production writes this column directly.
    func stampBlobUseForTesting(hash: String, at stamp: String) throws {
        let predicate = #Predicate<CachedBlobModel> { $0.contentHash == hash }
        var descriptor = FetchDescriptor<CachedBlobModel>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let row = try modelContext.fetch(descriptor).first else { return }
        row.lastUsedAt = stamp
        try modelContext.save()
    }
}
