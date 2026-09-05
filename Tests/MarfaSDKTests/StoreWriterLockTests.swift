import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// One writer per store.
///
/// Nothing enforced this before: `MarfaModelContainer`'s creation lock is an
/// in-process `NSLock` around building a container, and `SyncEngine.running`
/// is a per-instance flag. So two clients over one store path — two
/// `MarfaClient.synced(...)` in a process, or an app and a share extension
/// over an App Group container — got two engines, two drains and two cursors,
/// with nothing anywhere saying so.
@Suite("One writer per store", .timeLimit(.minutes(1)))
struct StoreWriterLockTests {

    private func tempStorePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("marfa-lock-\(UUID().uuidString)")
            .appendingPathComponent("store.sqlite")
            .path
    }

    @Test("a second opener is refused rather than queued")
    func aSecondOpenerIsRefused() throws {
        let path = tempStorePath()
        let first = try StoreWriterLock.acquire(storePath: path)
        #expect(first.writer)

        let second = try StoreWriterLock.acquire(storePath: path)
        #expect(second.writer == false)
        #expect(second.heldBy != nil, "a refusal has to say who has it")

        first.release()
        let third = try StoreWriterLock.acquire(storePath: path)
        #expect(third.writer, "releasing has to actually let the next one in")
        third.release()
    }

    /// Taken before the database is opened, because a store this build cannot
    /// read must not be moved aside by a caller that does not hold the write.
    /// So on a first launch nothing has made the directory yet — and a claim
    /// that fails on the missing parent, gets caught, and reports contention
    /// refuses every write for the life of the process with nothing raised.
    @Test("a first launch makes its own directory rather than reporting contention")
    func aFirstLaunchCreatesItsDirectory() throws {
        let path = tempStorePath()
        #expect(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent) == false)

        let lock = try StoreWriterLock.acquire(storePath: path)
        #expect(lock.writer, "a missing directory is not somebody else holding the lock")
        lock.release()
    }

    /// A crashed engine must not make its own store permanently read-only.
    @Test("a holder that is no longer running is taken over")
    func aDeadHolderIsTakenOver() throws {
        let path = tempStorePath()
        let lockPath = try #require(StoreWriterLock.lockPath(for: path))
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        // A pid nothing is running under, written under this boot so the boot
        // check cannot be what rejects it.
        let dead = StoreLockHolder(
            pid: 999_999, token: "gone", since: "then",
            bootedAt: StoreWriterLock.machineBootedAt(), startedAt: nil
        )
        try JSONEncoder().encode(dead).write(to: URL(fileURLWithPath: lockPath))

        let lock = try StoreWriterLock.acquire(storePath: path)
        #expect(lock.writer)
        lock.release()
    }

    /// A pid is not an identity across a restart: the machine reboots, the
    /// number is handed out again, and a liveness check answers yes for
    /// something unrelated — leaving the store read-only for ever.
    ///
    /// **This is the fallback path**, taken when no process start time is
    /// available — an older lockfile, or a platform that declines to answer
    /// for a process this one does not own. Where a start time exists it is
    /// asked first and the boot is not consulted at all.
    @Test("with no start time to compare, a holder from a previous boot is stale")
    func aHolderFromAnotherBootIsStale() {
        let live = StoreLockHolder(
            pid: ProcessInfo.processInfo.processIdentifier, token: "t", since: "now",
            bootedAt: StoreWriterLock.machineBootedAt(), startedAt: nil
        )
        #expect(StoreWriterLock.stillHolding(live))

        // The discriminator: the same running process, written under a boot
        // that is not this one. Without it this would pass against a build
        // that never checks the boot at all.
        let previousBoot = StoreLockHolder(
            pid: live.pid, token: live.token, since: live.since,
            bootedAt: live.bootedAt - 1, startedAt: nil
        )
        #expect(StoreWriterLock.stillHolding(previousBoot) == false)
    }

    /// **A recorded start time outranks a moved boot instant**, and the order
    /// is the point rather than a detail.
    ///
    /// `kern.boottime` is not immovable within one boot — a calendar step, an
    /// NTP correction, a manual date change moves it. An equality test on it,
    /// asked first, would then declare a live holder dead and hand the caller
    /// the takeover path, which is how a lock ends up held twice. A start time
    /// that still matches is direct evidence the holder is the same process,
    /// and it needs no tolerance window to say so.
    @Test("a live holder survives the boot instant moving under it")
    func aStartTimeOutranksAMovedBoot() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let started = try #require(StoreWriterLock.processStartedAt(pid: pid))

        let clockStepped = StoreLockHolder(
            pid: pid, token: "t", since: "now",
            bootedAt: StoreWriterLock.machineBootedAt() - 1, startedAt: started
        )
        #expect(StoreWriterLock.stillHolding(clockStepped), "still the same process")
    }

    /// The case a boot instant cannot see, and the one Darwin lets this kit
    /// close where a portable interface cannot: the boot matches, the pid is
    /// live, and it is running something else.
    @Test("a recycled process id within one boot is not treated as the same holder")
    func aRecycledPidIsNotTheSameHolder() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let started = try #require(
            StoreWriterLock.processStartedAt(pid: pid),
            "Darwin should answer for this process; the fallback path is the portable one"
        )

        let impostor = StoreLockHolder(
            pid: pid, token: "t", since: "now",
            bootedAt: StoreWriterLock.machineBootedAt(),
            startedAt: started - 1
        )
        #expect(StoreWriterLock.stillHolding(impostor) == false)
    }

    /// Releasing compares the token, never the process id — otherwise this
    /// process can drop a hold it took, lost, and had taken over in between.
    @Test("releasing a hold somebody else now has leaves theirs alone")
    func releasingComparesTheToken() throws {
        let path = tempStorePath()
        let mine = try StoreWriterLock.acquire(storePath: path)
        #expect(mine.writer)

        // Somebody else's hold, in place of mine.
        let lockPath = try #require(StoreWriterLock.lockPath(for: path))
        let theirs = StoreLockHolder(
            pid: 4242, token: "theirs", since: "now",
            bootedAt: StoreWriterLock.machineBootedAt(), startedAt: nil
        )
        try JSONEncoder().encode(theirs).write(to: URL(fileURLWithPath: lockPath))

        mine.release()
        #expect(
            FileManager.default.fileExists(atPath: lockPath),
            "releasing on a pid would have deleted a hold this caller no longer had"
        )
        try? FileManager.default.removeItem(atPath: lockPath)
    }

    /// A lockfile that will not parse is one nothing valid ever wrote: the
    /// claim puts the holder in place atomically, so there is no half-written
    /// state to meet. Treating it as nobody's is what stops a store nothing
    /// can ever open again.
    @Test("an unreadable lockfile is nobody's rather than everybody's")
    func anUnreadableLockfileIsTakenOver() throws {
        let path = tempStorePath()
        let lockPath = try #require(StoreWriterLock.lockPath(for: path))
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: URL(fileURLWithPath: lockPath))

        let lock = try StoreWriterLock.acquire(storePath: path)
        #expect(lock.writer)
        lock.release()
    }

    /// An in-memory store is not a location. Each container gets its own
    /// private database, so two `:memory:` stores are unrelated things that
    /// happen to share a spelling — and a first version keyed them all under
    /// that spelling, so one client built in an unrelated test and never
    /// released held the name for the life of the process and reported every
    /// later in-memory store as somebody else's.
    @Test("in-memory stores do not contend with each other")
    func inMemoryStoresDoNotContend() throws {
        let first = try StoreWriterLock.acquire(storePath: ":memory:")
        let second = try StoreWriterLock.acquire(storePath: ":memory:")
        #expect(first.writer)
        #expect(second.writer, "two in-memory stores are two stores")
        first.release()
        second.release()
    }

    // MARK: - What the lock is for

    /// The lock is only worth having if an engine respects it. A second engine
    /// over one store is the failure: two cursors, each believing it is the
    /// one draining, with half the writes replayed twice.
    @Test("an engine without the writer lock does not start")
    func aNonWriterEngineDoesNotStart() async throws {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        let transport = MockTransport()
        let connManager = ConnectionStateManager()
        let engine = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, isStoreWriter: false
        )

        transport.enqueueEvents([])
        await engine.start()
        await connManager.applyStateForTesting(.connecting)
        #expect(transport.calls.isEmpty, "a reader must not open a stream or drain")

        // The discriminator: the same engine holding the lock does start, so
        // the silence above is about the lock rather than about the fixture
        // being inert.
        let writer = SyncEngine(
            transport: transport, localStore: store, mutationQueue: queue,
            connectionManager: connManager, isStoreWriter: true
        )
        transport.enqueueEvents([])
        await writer.start()
        try await SyncEngineTestKit.awaitCondition(description: "the writer opened a stream") {
            transport.calls.contains { $0.path == "/events" }
        }
        await writer.stop()
    }

    // MARK: - The window a review found

    /// **Two openers meeting one stale lock must not both come away as
    /// writer**, and an earlier version let them.
    ///
    /// Clearing by unlink removes whatever is at the path *now*, not the dead
    /// holder just read — so both find it dead, both clear, and the second
    /// clears the first's fresh claim. Both hold, and the first's release is
    /// then a no-op because its token no longer matches, so it never cleans up
    /// either. Clearing by rename is atomic: exactly one caller can succeed,
    /// and the loser re-reads rather than removing a claim somebody has just
    /// made.
    @Test("two openers meeting one stale lock produce exactly one writer")
    func onlyOneOpenerTakesOverAStaleLock() async throws {
        let path = tempStorePath()
        let lockPath = try #require(StoreWriterLock.lockPath(for: path))
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let dead = StoreLockHolder(
            pid: 999_999, token: "gone", since: "then",
            bootedAt: StoreWriterLock.machineBootedAt(), startedAt: nil
        )
        try JSONEncoder().encode(dead).write(to: URL(fileURLWithPath: lockPath))

        // The in-process guard would settle this on its own, so it is stood
        // down for the length of the race: what is under test is the
        // filesystem claim, which is what two *processes* would contend over.
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    StoreWriterLock.clearedStaleLockForTesting(at: lockPath)
                }
            }
            var won = 0
            for await didClear in group where didClear { won += 1 }
            return won
        }
        #expect(winners == 1, "both openers cleared the same stale lock")
    }
}
