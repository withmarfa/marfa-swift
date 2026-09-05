import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// A store knows which server it belongs to.
///
/// **There is nothing to reconcile, which is why this refuses.** A store holds
/// one server's rows, one event cursor and a queue of writes addressed to that
/// server. Opening it against a different origin does not produce a store with
/// two servers' data in it — it produces one where every later answer
/// overwrites rows that were never the same rows, and a queue that replays
/// somebody's edits at a server that has never heard of them. Nothing
/// afterwards tells that apart from ordinary drift.
@Suite("A store knows whose it is", .timeLimit(.minutes(1)))
struct StoreIdentityTests {

    /// A real path on disk, because the origin lives beside the store rather
    /// than inside it — it has to be readable before the database opens.
    private func tempStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("marfa-origin-\(UUID().uuidString)")
            .appendingPathComponent("store.sqlite")
            .path
    }

    @Test("a writer claims an unclaimed store; a reader leaves it unclaimed")
    func onlyAWriterClaims() throws {
        let path = tempStorePath()
        #expect(StoreOriginFile.recorded(storePath: path) == nil)

        // A reader over an unclaimed store must not stamp an origin the
        // writer never chose.
        try StoreOriginFile.check(
            storePath: path, origin: "https://api.marfa.so", claiming: false
        )
        #expect(StoreOriginFile.recorded(storePath: path) == nil)

        try StoreOriginFile.check(
            storePath: path, origin: "https://api.marfa.so", claiming: true
        )
        #expect(StoreOriginFile.recorded(storePath: path) == "https://api.marfa.so")
    }

    @Test("reopening against the same origin is not a mismatch")
    func theSameOriginReopens() throws {
        let path = tempStorePath()
        try StoreOriginFile.check(storePath: path, origin: "https://api.marfa.so", claiming: true)
        try StoreOriginFile.check(storePath: path, origin: "https://api.marfa.so", claiming: true)
    }

    /// **A reader compares even though it does not record.** Gating both on
    /// the writer lock left a reader serving one server's rows through a
    /// client configured for another — the same failure on the read side.
    @Test("a reader is refused by an origin it does not match")
    func aReaderComparesToo() throws {
        let path = tempStorePath()
        try StoreOriginFile.check(storePath: path, origin: "https://staging.marfa.so", claiming: true)

        #expect(throws: StoreIdentityMismatchError.self) {
            try StoreOriginFile.check(
                storePath: path, origin: "https://api.marfa.so", claiming: false
            )
        }
    }

    /// The failure this exists for: a store built against staging opened
    /// against production, or the reverse.
    @Test("another origin is refused, and the refusal names both")
    func anotherOriginIsRefused() throws {
        let path = tempStorePath()
        try StoreOriginFile.check(storePath: path, origin: "https://staging.marfa.so", claiming: true)

        let thrown = #expect(throws: StoreIdentityMismatchError.self) {
            try StoreOriginFile.check(
                storePath: path, origin: "https://api.marfa.so", claiming: true
            )
        }
        #expect(thrown?.axis == .origin)
        #expect(thrown?.recorded == "https://staging.marfa.so")
        #expect(thrown?.found == "https://api.marfa.so")
        // Permanent by construction: nothing about a later attempt differs,
        // so a queue that retried this would retry it for ever.
        #expect(thrown?.isPermanent == true)
    }

    /// **A trailing slash is the same server**, and refusing over it would be
    /// a false refusal on a difference nobody made. `ClientConfiguration`
    /// takes whatever URL a consumer passes.
    @Test("two spellings of one server are one origin")
    func spellingsAreNormalized() {
        let plain = MarfaClient.canonicalOrigin(URL(string: "https://api.marfa.so")!)
        let slashed = MarfaClient.canonicalOrigin(URL(string: "https://api.marfa.so/")!)
        let shouted = MarfaClient.canonicalOrigin(URL(string: "https://API.Marfa.so")!)
        #expect(plain == slashed)
        #expect(plain == shouted)

        // The discriminator: normalization must not collapse two real servers.
        let other = MarfaClient.canonicalOrigin(URL(string: "https://staging.marfa.so")!)
        #expect(plain != other)
    }

    // MARK: - Through the door a consumer actually uses

    /// **Nothing reached the claim through `synced`, and two defects lived in
    /// exactly that gap.** Deleting the whole check from `synced` left the
    /// unit suite green, because every test drove the sidecar directly. The
    /// existing fixtures all use `:memory:`, which has no file and belongs to
    /// nobody, so the path was unreachable as well as untested.
    @Test("a client refuses a store that belongs to another server")
    func syncedRefusesAnotherOrigin() async throws {
        let path = tempStorePath()

        let first = try await MarfaClient.synced(
            url: URL(string: "https://staging.marfa.so")!, apiKey: "k", storePath: path
        )
        #expect(first.holdsStoreWriteLock)
        #expect(StoreOriginFile.recorded(storePath: path) == "https://staging.marfa.so")

        await #expect(throws: StoreIdentityMismatchError.self) {
            _ = try await MarfaClient.synced(
                url: URL(string: "https://api.marfa.so")!, apiKey: "k", storePath: path
            )
        }
    }

    /// The refusal must not cost the process its ability to write.
    ///
    /// The lock is a struct with no `deinit`, and the only release is the
    /// client's — so a `synced` that threw after taking it left the hold in a
    /// process-global set for ever. An origin mismatch throws every time,
    /// which turned a latent leak into a certain one: the intended refusal,
    /// and then every later open silently read-only, including against the
    /// server the store does belong to.
    @Test("a refused open gives the writer lock back")
    func aRefusedOpenReleasesTheLock() async throws {
        let path = tempStorePath()
        let staging = URL(string: "https://staging.marfa.so")!

        // Claim it, then let that client go so the lock is genuinely free.
        do {
            let owner = try await MarfaClient.synced(url: staging, apiKey: "k", storePath: path)
            #expect(owner.holdsStoreWriteLock)
        }

        await #expect(throws: StoreIdentityMismatchError.self) {
            _ = try await MarfaClient.synced(
                url: URL(string: "https://api.marfa.so")!, apiKey: "k", storePath: path
            )
        }

        // The origin it does belong to must still be openable, and writable.
        let recovered = try await MarfaClient.synced(url: staging, apiKey: "k", storePath: path)
        #expect(recovered.holdsStoreWriteLock, "the refusal kept the lock it took")
    }
}
