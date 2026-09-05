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

        // **Every opener HOLDS its lock until all of them have tried**, and
        // that is not decoration. A probe whose winners let go — by exiting,
        // or by releasing — makes each winner's lock genuinely stale, so the
        // next opener correctly takes it over and the run counts several
        // "writers" for a lock that was working perfectly. Chunk B's probe had
        // exactly that shape and its measurements had to be withdrawn.
        //
        // Holding also makes the count mean something: at the end, exactly one
        // opener should be holding, and the file on disk should carry that
        // one's token.
        let held = await withTaskGroup(of: StoreWriterLock?.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    // The in-process guard would settle this before the
                    // filesystem was reached, and the filesystem is what two
                    // processes would contend over.
                    StoreWriterLock.forgetInProcessHoldForTesting(storePath: path)
                    let lock = try? StoreWriterLock.acquire(storePath: path)
                    return (lock?.writer == true) ? lock : nil
                }
            }
            var locks: [StoreWriterLock] = []
            for await lock in group { if let lock { locks.append(lock) } }
            return locks
        }
        let writers = held.count

        #expect(writers == 1, "round \(round): \(writers) writers over one stale lock")

        // Zero writers would be as wrong as two and nothing asserted it: a
        // build where everybody refuses leaves a store nothing can ever open.
        #expect(writers > 0, "round \(round): nobody took over a stale lock")

        // And the winner is the one on disk. Without this the count could be
        // right while the file belonged to somebody who had already lost.
        let lockPath = try #require(StoreWriterLock.lockPath(for: path))
        let onDisk = try #require(FileManager.default.contents(atPath: lockPath))
        let holder = try JSONDecoder().decode(StoreLockHolder.self, from: onDisk)
        #expect(holder.pid == ProcessInfo.processInfo.processIdentifier)
    }
}
