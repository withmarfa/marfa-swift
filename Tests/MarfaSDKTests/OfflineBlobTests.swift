import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// A blob this device already has is readable without the network.
///
/// **The defect this closes is the one a person actually met.** The only copy
/// a device held of a blob it had uploaded was the outbound buffer, and that
/// row is deleted the moment the upload succeeds. So you could save a
/// picture, watch it sync, and then not open it on a train — every read went
/// back to the network for a file the device had held minutes earlier.
///
/// A hash is a content address, so a cached copy can never be the wrong
/// answer: there is no version to be behind and no staleness to reason about.
/// That is what makes a read-through cache correct here rather than merely
/// fast.
@Suite("A blob you saved is readable offline", .timeLimit(.minutes(1)))
struct OfflineBlobTests {

    private let bytes = Data("a picture, imagine".utf8)

    /// The symptom, end to end: upload it, let the queue drain, then read it
    /// with a transport that refuses everything.
    @Test("a blob survives its own successful upload")
    func uploadedBytesOutliveTheUpload() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let hash = "sha256:" + String(repeating: "a", count: 64)
        // Enqueued directly, with NO cache entry — the shape a row written by
        // an earlier build has, and the only shape that puts the replay's own
        // cache write under test. A draft primed the cache here first and so
        // asserted its own setup: deleting the line the test exists to cover
        // left it green.
        try await queue.enqueueBlobUpload(hash: hash, data: bytes, mimeType: "image/png")
        #expect(try await store.cachedBlob(hash: hash) == nil)

        transport.enqueueRaw(
            data: Data(#"{"hash":"\#(hash)","mime_type":"image/png","size":18}"#.utf8),
            statusCode: 200
        )
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "the upload drained") {
            try await queue.fetchPendingBlob(hash: hash) == nil
        }

        // The outbound buffer is gone, as it should be. The bytes are not.
        let cached = try await store.cachedBlob(hash: hash)
        #expect(cached?.data == bytes)
        #expect(cached?.mimeType == "image/png")
        await engine.stop()
    }

    /// A pure-local client has no server at all, so this is the strongest form
    /// of "offline": the read cannot fall back even in principle.
    @Test("a local-only client reads a blob it holds, and refuses one it does not")
    func aLocalClientServesWhatItHolds() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        let hash = "sha256:" + String(repeating: "b", count: 64)
        try await store.cacheBlob(hash: hash, data: bytes, mimeType: "image/png")

        let (data, mime) = try await client.blobs.download(hash: hash)
        #expect(data == bytes)
        #expect(mime == "image/png")

        // The discriminator: a hash it does not hold still refuses, so the
        // read above is about the cache rather than about local mode having
        // stopped refusing.
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.blobs.download(
                hash: "sha256:" + String(repeating: "c", count: 64)
            )
        }
    }

    // MARK: - Eviction

    /// The rule is least-recently-**used**, so a read moves a row's place in
    /// it. A file opened every day should outlive one fetched once and never
    /// opened again, and stamping only on write gets that exactly backwards.
    ///
    /// **The stamps are set explicitly rather than by writing quickly**, and a
    /// first draft did the latter and failed: `lastUsedAt` has millisecond
    /// resolution, so four operations in one test tie and the order between
    /// them is arbitrary. That is correct behaviour — rows used in the same
    /// millisecond are equally recent — and it makes wall-clock ordering the
    /// wrong way to state this property.
    @Test("a read keeps a blob alive that a write-only rule would evict")
    func readingRefreshesTheEvictionOrder() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)

        let old = "sha256:" + String(repeating: "1", count: 64)
        let recent = "sha256:" + String(repeating: "2", count: 64)
        let big = Data(repeating: 0, count: 600)

        try await store.cacheBlob(hash: old, data: big, mimeType: "application/octet-stream")
        try await store.stampBlobUseForTesting(hash: old, at: "2026-01-01T00:00:00.000Z")
        try await store.cacheBlob(hash: recent, data: big, mimeType: "application/octet-stream")
        try await store.stampBlobUseForTesting(hash: recent, at: "2026-01-02T00:00:00.000Z")

        // Reading the older one is what should save it.
        _ = try await store.cachedBlob(hash: old)

        // A bound that fits one 600-byte row beside the new one.
        try await store.cacheBlob(
            hash: "sha256:" + String(repeating: "3", count: 64),
            data: big, mimeType: "application/octet-stream", limit: 1_300
        )

        #expect(try await store.cachedBlob(hash: old) != nil, "the read should have saved it")
        #expect(try await store.cachedBlob(hash: recent) == nil)
    }

    @Test("the cache stays under its bound")
    func evictionHoldsTheBound() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        let chunk = Data(repeating: 7, count: 400)

        for i in 0..<10 {
            try await store.cacheBlob(
                hash: "sha256:" + String(format: "%064d", i),
                data: chunk, mimeType: "application/octet-stream", limit: 1_000
            )
        }
        let held = try await store.cachedBlobBytes()
        #expect(held <= 1_000, "held \(held) bytes against a 1000-byte bound")
        // Not an idle assertion: a bound is satisfied by an empty cache, so
        // without this the rule "stay under the bound" is met by a cache that
        // keeps nothing. A blob that cannot fit is refused separately —
        // `anOversizedBlobDoesNotFlushTheCache` covers that.
        #expect(held > 0, "evicting everything satisfies the bound and defeats the cache")
    }

    // MARK: - What the review found the comments claiming

    /// The hash covers the bytes. It does not cover the MIME type, which
    /// reaches this cache from three authorities and only agrees by luck.
    ///
    /// A first version refreshed the use stamp alone on a re-cache, so the
    /// first writer won for ever: one hash gave two answers depending on
    /// whether this device's cache happened to be warm.
    @Test("a later writer corrects a MIME type the hash cannot vouch for")
    func aLaterWriteCorrectsTheMimeType() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        let hash = "sha256:" + String(repeating: "d", count: 64)

        try await store.cacheBlob(hash: hash, data: bytes, mimeType: "application/octet-stream")
        try await store.cacheBlob(hash: hash, data: bytes, mimeType: "image/png")

        #expect(try await store.cachedBlob(hash: hash)?.mimeType == "image/png")
    }

    /// A blob too large to keep is not cached, rather than cached and then
    /// evicting everything to make room it will not get. Without the guard
    /// one large video flushes a person's whole cache for no gain.
    @Test("a blob larger than the bound does not empty the cache")
    func anOversizedBlobDoesNotFlushTheCache() async throws {
        let client = try await MarfaSDKTest.makeInMemoryClient()
        let store = try #require(client.localStore)
        let small = Data(repeating: 1, count: 400)

        for i in 0..<3 {
            try await store.cacheBlob(
                hash: "sha256:" + String(format: "%064d", i),
                data: small, mimeType: "application/octet-stream", limit: 2_000
            )
        }
        #expect(try await store.cachedBlobBytes() == 1_200)

        try await store.cacheBlob(
            hash: "sha256:" + String(repeating: "e", count: 64),
            data: Data(repeating: 2, count: 5_000),
            mimeType: "video/mp4", limit: 2_000
        )

        #expect(try await store.cachedBlobBytes() == 1_200, "the cache was flushed for nothing")
    }

    /// A hash mismatch means the local hash was wrong and every reference to
    /// it will 404 elsewhere. Caching under it would make this one device the
    /// only place those bytes resolve, silently masking the diagnostic the
    /// mismatch log exists to raise.
    @Test("bytes the server addressed differently are not cached under the local hash")
    func aHashMismatchIsNotCached() async throws {
        let (store, queue, transport, _, engine) = try await SyncEngineTestKit.makeFixture()
        transport.enqueueEvents([])
        await engine.start()

        let localHash = "sha256:" + String(repeating: "f", count: 64)
        let serverHash = "sha256:" + String(repeating: "9", count: 64)
        try await queue.enqueueBlobUpload(hash: localHash, data: bytes, mimeType: "image/png")

        transport.enqueueRaw(
            data: Data(#"{"hash":"\#(serverHash)","mime_type":"image/png","size":18}"#.utf8),
            statusCode: 200
        )
        await engine.replayMutationsForTesting()
        try await SyncEngineTestKit.awaitCondition(description: "the upload drained") {
            try await queue.fetchPendingBlob(hash: localHash) == nil
        }

        #expect(try await store.cachedBlob(hash: localHash) == nil)
        await engine.stop()
    }
}
