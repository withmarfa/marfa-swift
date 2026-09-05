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
}
