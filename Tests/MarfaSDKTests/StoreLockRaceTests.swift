import Testing
import Foundation
@testable import MarfaSDK

/// Many openers, one stale lock.
///
/// **Two openers cannot show this and the first version of these tests used
/// two.** The two-party interleaving is the one a rename closes: the loser's
/// rename fails because what it named is gone. What survives is a third
/// party — a loser that moves the winner's *fresh* lock aside to inspect it
/// leaves the path empty while it does, and anybody arriving in that gap
/// claims cleanly.
@Suite("Clearing a stale lock is exclusive", .timeLimit(.minutes(1)), .serialized)
struct StoreLockRaceTests {

    private func staleLockPath() throws -> String {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("marfa-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("store.sqlite").path
        let lockPath = try #require(StoreWriterLock.lockPath(for: path))
        let dead = StoreLockHolder(
            pid: 999_999, token: "gone", since: "then",
            bootedAt: StoreWriterLock.machineBootedAt(), startedAt: nil
        )
        try JSONEncoder().encode(dead).write(to: URL(fileURLWithPath: lockPath))
        return path
    }

    /// Twelve openers against one stale lock, several times over.
    ///
    /// The count and the repetition are both load-bearing: the residual window
    /// is microseconds wide and needs a third party to fall into it, so a
    /// two-opener probe reports clean against a build that races.
    @Test("many openers over one stale lock produce exactly one writer", arguments: 0..<30)
    func manyOpenersProduceOneWriter(_ round: Int) async throws {
        let path = try staleLockPath()

        let writers = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    // The in-process guard would settle this before the
                    // filesystem was reached, and the filesystem is what two
                    // processes would contend over. Cleared per task so each
                    // one really goes to disk.
                    StoreWriterLock.forgetInProcessHoldForTesting(storePath: path)
                    return ((try? StoreWriterLock.acquire(storePath: path))?.writer) ?? false
                }
            }
            var won = 0
            for await didWrite in group where didWrite { won += 1 }
            return won
        }

        #expect(writers == 1, "round \(round): \(writers) writers over one stale lock")
    }

    // MARK: - The right itself

    /// **A right left behind by a failed release must not hold the store for
    /// ever**, and asking whether its process is alive said exactly that.
    ///
    /// The lock names a process that holds it for as long as the client lives.
    /// The right names one inside a critical section measured in
    /// microseconds. So a `.clearing` whose unlink failed — the release is a
    /// `try?` and silent — named a process that was still running, was judged
    /// held, and refused every later open. Deterministic, no race needed.
    @Test("a right left by a live process is not held for ever")
    func aStaleRightDoesNotPoisonTheStore() throws {
        let path = try staleLockPath()
        let right = try #require(StoreWriterLock.lockPath(for: path)) + ".clearing"

        // A right this very process took, long enough ago to be abandoned.
        let old = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-StoreWriterLock.maxClearingRightAge - 60)
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        try JSONEncoder().encode(
            StoreLockHolder(
                pid: pid, token: "abandoned", since: old,
                bootedAt: StoreWriterLock.machineBootedAt(),
                startedAt: StoreWriterLock.processStartedAt(pid: pid)
            )
        ).write(to: URL(fileURLWithPath: right))

        let lock = try StoreWriterLock.acquire(storePath: path)
        #expect(lock.writer, "a store must not be read-only because a clear did not tidy up")
        lock.release()
    }

    /// The discriminator for the test above: a right taken a moment ago is
    /// somebody working, and must be respected.
    @Test("a right taken just now is respected")
    func aFreshRightIsRespected() throws {
        let path = try staleLockPath()
        let right = try #require(StoreWriterLock.lockPath(for: path)) + ".clearing"

        let pid = ProcessInfo.processInfo.processIdentifier
        try JSONEncoder().encode(
            StoreLockHolder(
                pid: pid, token: "working", since: ISO8601DateFormatter().string(from: Date()),
                bootedAt: StoreWriterLock.machineBootedAt(),
                startedAt: StoreWriterLock.processStartedAt(pid: pid)
            )
        ).write(to: URL(fileURLWithPath: right))

        let lock = try StoreWriterLock.acquire(storePath: path)
        #expect(lock.writer == false, "somebody is inside the critical section")
        try? FileManager.default.removeItem(atPath: right)
    }

    /// An unparseable right is one nothing valid ever wrote — the claim is
    /// atomic and leaves no half-written state to meet — and the main lock
    /// already handles the identical condition. The right, using the same
    /// helper, did not, so a single corrupt byte made the store unopenable.
    @Test("an unparseable right does not make the store unopenable")
    func anUnparseableRightIsTakenOver() throws {
        let path = try staleLockPath()
        let right = try #require(StoreWriterLock.lockPath(for: path)) + ".clearing"
        try Data("not json".utf8).write(to: URL(fileURLWithPath: right))

        let lock = try StoreWriterLock.acquire(storePath: path)
        #expect(lock.writer)
        lock.release()
    }

    /// A smoke check that the ordinary paths tidy up, and **not** a guard
    /// against the leak it looks like one for.
    ///
    /// Mutating a leak into the refusal path leaves this green, and leaves the
    /// race rounds green too — because that path is not reachable: nothing
    /// removes a right taken a moment ago, so a caller's own claim is still
    /// its own when it reads it back. Kept because it costs nothing and says
    /// the common paths are clean, and named for that rather than for a
    /// guarantee it does not give.
    @Test("the ordinary paths leave no right behind")
    func theRightIsAlwaysGivenBack() throws {
        let path = try staleLockPath()
        let right = try #require(StoreWriterLock.lockPath(for: path)) + ".clearing"

        let taken = try StoreWriterLock.acquire(storePath: path)
        #expect(taken.writer)
        #expect(FileManager.default.fileExists(atPath: right) == false)

        // And on a refusal, which is the path the leak was on.
        StoreWriterLock.forgetInProcessHoldForTesting(storePath: path)
        let refused = try StoreWriterLock.acquire(storePath: path)
        #expect(refused.writer == false)
        #expect(FileManager.default.fileExists(atPath: right) == false)

        taken.release()
    }
}
