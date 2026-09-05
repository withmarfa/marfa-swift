import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Who holds a store's writer lock.
public struct StoreLockHolder: Sendable, Equatable, Codable {
    /// The process that took it.
    public let pid: Int32

    /// Distinguishes this hold from any other, **including a later hold by
    /// this same process.** Without it, releasing means trusting a process id
    /// to identify a hold, and a process only ever holds one at a time by
    /// accident.
    public let token: String

    /// When it was taken, ISO 8601 — or a short phrase for a hold this
    /// process took, which has no file and therefore no stamp.
    public let since: String

    /// When the **machine** was started, not when the holder was.
    ///
    /// A process id is not an identity across a restart: the machine reboots,
    /// the number is handed out again, and a liveness check on it answers yes
    /// for a process that has nothing to do with this store — leaving it
    /// read-only for ever with nobody able to work out why. Comparing the boot
    /// the lock was written under against the current one settles that without
    /// inspecting a process this one does not own.
    ///
    /// **The value has to be one every process on the machine agrees on**, and
    /// that is easy to lose sight of while reasoning about reboots. A boot
    /// derived as *now minus this process's uptime* describes this process and
    /// reads as a plausible spelling of the same idea; it makes every process
    /// compute a different boot, so two started minutes apart each conclude
    /// the other belongs to a previous boot — not a rare race but every
    /// ordinary second launch, ending with both of them writing.
    public let bootedAt: Int64

    /// When the holding process started, where the platform will say.
    ///
    /// This is what closes the case ``bootedAt`` cannot: a process id recycled
    /// *within* one boot, where the boot matches and the liveness check answers
    /// yes for something unrelated. Rare, and the only reason it is closed here
    /// rather than documented as open is that Darwin will answer for a process
    /// this one does not own. `nil` where it would not — see
    /// ``StoreWriterLock/processStartedAt(pid:)``.
    public let startedAt: Int64?
}

/// The writer lock a store holds while an engine is writing to it.
public struct StoreWriterLock: Sendable {
    /// Whether this caller may write.
    public let writer: Bool

    /// Who has it, when this caller does not.
    public let heldBy: StoreLockHolder?

    private let releaseHandler: @Sendable () -> Void

    init(writer: Bool, heldBy: StoreLockHolder?, release: @escaping @Sendable () -> Void) {
        self.writer = writer
        self.heldBy = heldBy
        self.releaseHandler = release
    }

    /// Gives the lock up. Releasing one this caller does not hold does
    /// nothing, because the token is compared rather than the process id.
    public func release() { releaseHandler() }
}

// MARK: - Taking it

extension StoreWriterLock {

    /// Holds taken by this process, so a second opener here is refused
    /// without going near the filesystem.
    ///
    /// **Not because a link can contend with itself — it cannot**, and a
    /// first version said so wrongly: a second `link` over an existing target
    /// from the same process returns `EEXIST` like any other. What this
    /// narrows is the window between clearing a stale lock and claiming it,
    /// where two callers in one process would otherwise both go looking. It
    /// is also faster than a filesystem round trip for the common case of an
    /// app opening its own store twice.
    private static let inProcess = InProcessHolds()

    /// Takes the writer lock for a store, or reports who has it.
    ///
    /// **Never blocks and never waits.** A second opener is told it cannot
    /// write rather than being queued behind a holder that may never let go,
    /// because a caller can do something useful with a read-only store and can
    /// do nothing at all with a promise that has not settled.
    ///
    /// Throws only when this machine cannot take a lock **nobody is holding** —
    /// a read-only volume, a full disk, a sandbox refusing the container. That
    /// distinction is the whole error handling: reporting those as contention
    /// produces a holder nobody can find and a store that refuses every write
    /// for the life of the process with nothing raised.
    public static func acquire(storePath: String) throws -> StoreWriterLock {
        guard let path = lockPath(for: storePath) else {
            // **An in-memory store never contends, and a first version had it
            // contending with itself.** `:memory:` is not a location: each
            // container gets its own private database, so two of them are
            // unrelated stores that happen to share a spelling. Keying them
            // all under that spelling made one unrelated caller — a client
            // built in a test and never released — hold the name for the life
            // of the process and report every later in-memory store as
            // somebody else's. There is nothing here to exclude.
            return StoreWriterLock(writer: true, heldBy: nil, release: {})
        }

        guard inProcess.take(path) else {
            return StoreWriterLock(writer: false, heldBy: heldHere(), release: {})
        }

        // The lock is taken BEFORE the database is opened, because a store
        // this build cannot read must not be moved aside by a caller that
        // does not hold the write — so on a first launch nothing has made the
        // directory yet. It goes here rather than in the caller because the
        // lock needs its own directory whether or not a database is ever
        // opened beside it.
        let token = UUID().uuidString
        do {
            // **Inside the `do`, and it was outside.** A throw here left the
            // in-process key taken with nothing to give it back, so every
            // later open in this process was refused for a cause that had
            // since gone — the store permanently read-only with nothing
            // raised, which is the exact outcome the error discrimination
            // below exists to prevent, arriving through the one statement the
            // recovery did not cover.
            let directory = (path as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: directory) {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true
                )
            }

            guard try claim(path: path, token: token) else {
                let holder = readHolder(path: path)
                // A holder that is not running left the file behind when it
                // died. Take it over rather than refusing for ever: a crashed
                // engine must not make its own store permanently read-only.
                if let holder, stillHolding(holder) {
                    inProcess.give(path)
                    return StoreWriterLock(writer: false, heldBy: holder, release: {})
                }
                // **Cleared by rename, not by unlink, and that is the whole
                // difference between one writer and two.**
                //
                // An unlink removes whatever is at the path *now*, not the
                // dead holder just read — so two openers meeting one stale
                // lock both find it dead, both clear, and the second clears
                // the first's fresh claim. Both come away as writer, and the
                // first's release is then a no-op because the token no longer
                // matches, so it never cleans up either. The trigger is
                // ordinary: an app and its share extension starting together
                // after a crash left a lockfile behind.
                //
                // A rename is atomic and names the file it is moving, so
                // exactly one caller can succeed. The loser's rename fails
                // because what it named is gone, and it re-reads rather than
                // clearing a claim somebody else has just made.
                guard tookOverStaleLock(at: path, token: token) else {
                    inProcess.give(path)
                    return StoreWriterLock(
                        writer: false, heldBy: readHolder(path: path) ?? unknownHolder(),
                        release: {}
                    )
                }
                return held(path: path, token: token)
            }
            return held(path: path, token: token)
        } catch {
            inProcess.give(path)
            throw error
        }
    }

    private static func held(path: String, token: String) -> StoreWriterLock {
        StoreWriterLock(writer: true, heldBy: nil, release: {
            // **The token is compared, never the process id.** Releasing on a
            // pid means this process can drop a hold it took, lost, and had
            // taken over by something else in between.
            if readHolder(path: path)?.token == token {
                try? FileManager.default.removeItem(atPath: path)
            }
            inProcess.give(path)
        })
    }

    /// Takes over a stale lock: clears it **and** claims it, under one right.
    ///
    /// **Three versions of this raced and each failure taught the next one
    /// something, so the reasoning is here rather than in a commit nobody
    /// will find.**
    ///
    /// Renaming the file aside is atomic, so only one caller moves any given
    /// file — but a loser still carrying an earlier read moves the *winner's
    /// fresh lock* aside to inspect it, and the path is empty while it does.
    /// A third opener claims in that gap. Twelve openers over thirty rounds
    /// found it; two openers never will.
    ///
    /// Taking an exclusive right to clear does not close it either. The right
    /// says nobody else is clearing; it says nothing about the file still
    /// being the one you judged dead, so a straggler carrying an older read
    /// can win the right afterwards and unlink a lock that is now live.
    ///
    /// Re-reading the holder under the right fixes that and still races,
    /// because **the right ended at the clear and the claim happened outside
    /// it.** Two callers could both come away with the path legitimately
    /// clear — one removed the dead file, the other arrived to find it
    /// already gone — and then both claim. The atomic link makes one of them
    /// lose, which is why this took thirty rounds under load to see.
    ///
    /// So the right covers the whole takeover. Clear and claim are one
    /// critical section, and a caller who does not hold it never touches the
    /// file.
    private static func tookOverStaleLock(at path: String, token: String) -> Bool {
        let right = path + ".clearing"
        guard (try? takeClearingRight(at: right, token: token)) == true else { return false }
        defer { try? FileManager.default.removeItem(atPath: right) }

        if let holder = readHolder(path: path) {
            // Somebody live got here first. Refuse against them rather than
            // clearing a lock that is no longer the one judged dead.
            guard !stillHolding(holder) else { return false }
            try? FileManager.default.removeItem(atPath: path)
        } else {
            // Either nothing is there or something unparseable is, and both
            // want the same answer. A lockfile that will not parse is one
            // nothing valid ever wrote — the claim puts its holder in place
            // atomically and leaves no half-written state to meet — and
            // leaving it would make the store unopenable for ever.
            try? FileManager.default.removeItem(atPath: path)
        }

        return ((try? claim(path: path, token: token)) == true)
    }

    /// The exclusive right to clear one store's lock.
    ///
    /// Taken through the same link-into-place claim the lock itself uses, so
    /// a reader of the right never meets a file that exists and is empty.
    private static func takeClearingRight(at right: String, token: String) throws -> Bool {
        if try claim(path: right, token: token) { return true }
        // A right nobody is holding was left by a crash. Without this, one
        // crashed clearer makes every stale lock on that store permanently
        // unclearable — the store read-only for good, which is the outcome
        // the whole file is written to avoid.
        if let holder = readHolder(path: right), !stillHolding(holder) {
            try? FileManager.default.removeItem(atPath: right)
            return try claim(path: right, token: token)
        }
        return false
    }

    /// A holder for the case where the lock is held and the file has already
    /// moved on — contended, by somebody this caller cannot name.
    ///
    /// A `nil` here would answer "who has it" with "nobody", which is the one
    /// answer that is certainly wrong when the caller has just been refused.
    private static func unknownHolder() -> StoreLockHolder {
        StoreLockHolder(
            pid: -1, token: "unknown", since: "unknown",
            bootedAt: machineBootedAt(), startedAt: nil
        )
    }

    /// Drops this process's record of holding a path, so a test can contend
    /// over the filesystem the way two processes would. Nothing else calls it.
    static func forgetInProcessHoldForTesting(storePath: String) {
        if let path = lockPath(for: storePath) { inProcess.give(path) }
    }

    /// The atomic clear, reachable from a test so the race it exists to
    /// settle can actually be run. Nothing else calls it.
    static func tookOverStaleLockForTesting(at path: String) -> Bool {
        tookOverStaleLock(at: path, token: UUID().uuidString)
    }

    private static func heldHere() -> StoreLockHolder {
        StoreLockHolder(
            pid: ProcessInfo.processInfo.processIdentifier,
            token: "held-here", since: "this process",
            bootedAt: machineBootedAt(), startedAt: nil
        )
    }

    /// Where a store's lock lives. `nil` for an in-memory store.
    static func lockPath(for storePath: String) -> String? {
        storePath == ":memory:" ? nil : storePath + ".lock"
    }

    /// Takes the lock with the holder already in it.
    ///
    /// **Written to a private file and then hard-linked into place**, because
    /// `link` fails when the target exists *and* carries the payload with it.
    /// An exclusive create followed by a write is not the same thing: between
    /// the two the file exists and is empty, and a second opener arriving there
    /// finds a file it cannot read, concludes nobody holds it, removes it and
    /// claims — so both believe they hold the lock and the first writes into a
    /// file that is no longer linked to anything.
    ///
    /// Returns `false` only for `EEXIST`, which is contention. Everything else
    /// throws: it is this machine being unable to take a lock nobody holds, and
    /// reporting that as contention is what hides it.
    private static func claim(path: String, token: String) throws -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let staging = "\(path).\(pid).\(token).claim"
        let holder = StoreLockHolder(
            pid: pid, token: token,
            since: ISO8601DateFormatter().string(from: Date()),
            bootedAt: machineBootedAt(),
            startedAt: processStartedAt(pid: pid)
        )
        defer {
            // Never created, or already gone. The link, if it was made, keeps
            // the content alive independently of this name.
            try? FileManager.default.removeItem(atPath: staging)
        }
        try JSONEncoder().encode(holder).write(to: URL(fileURLWithPath: staging))

        if link(staging, path) == 0 { return true }
        if errno == EEXIST { return false }
        throw LocalStoreError.storeQuarantineFailed(
            "could not take the writer lock at \(path): \(String(cString: strerror(errno)))"
        )
    }

    private static func readHolder(path: String) -> StoreLockHolder? {
        // A lockfile that will not parse is one nothing valid ever wrote — the
        // claim above puts the holder in place atomically, so there is no
        // half-written state to meet. Treating it as nobody's is right; the
        // alternative is a store nothing can ever open again.
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(StoreLockHolder.self, from: data)
    }

    /// Whether the process a holder names can still be holding anything.
    static func stillHolding(_ holder: StoreLockHolder) -> Bool {
        guard alive(pid: holder.pid) else { return false }

        // **The process start time is asked FIRST where it exists, and the
        // boot instant is the fallback.** That order matters: `kern.boottime`
        // is not immovable within one boot — a calendar step, an NTP
        // correction, a manual date change, moves it — and an equality test on
        // it would then call a live holder dead and hand this caller the
        // takeover path. A start time that still matches is direct evidence
        // the holder is the same process, and it needs no tolerance window to
        // say so.
        if let then = holder.startedAt, let now = processStartedAt(pid: holder.pid) {
            return then == now
        }

        // No start time to compare, so the boot is all there is. A pid is not
        // an identity across a restart: the machine reboots, the number is
        // handed out again, and liveness on it answers yes for something
        // unrelated — which would keep this store read-only for good.
        return holder.bootedAt == machineBootedAt()
    }

    /// Whether a process is still there to hold anything.
    private static func alive(pid: Int32) -> Bool {
        // Signal 0 performs the permission and existence checks and delivers
        // nothing, which is the portable way to ask. `EPERM` means the process
        // exists and belongs to somebody else, which is still a live holder;
        // only `ESRCH` says nothing is there.
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// The holds this process has, guarded for concurrent openers.
private final class InProcessHolds: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    func take(_ key: String) -> Bool {
        lock.withLock { keys.insert(key).inserted }
    }

    func give(_ key: String) {
        _ = lock.withLock { keys.remove(key) }
    }
}

// MARK: - What the machine will say

extension StoreWriterLock {

    /// When this machine started, in milliseconds since the epoch.
    ///
    /// **Read as an instant rather than derived from an uptime**, and the
    /// difference is not cosmetic. `now - uptime` is two readings taken a
    /// moment apart, and an uptime with second granularity puts two correct
    /// answers a little way from each other — so a portable implementation
    /// needs a tolerance window, and a tolerance window is a thing that can be
    /// tuned wrong. `KERN_BOOTTIME` is the instant itself, so every process on
    /// the machine reads the same number and equality is the comparison.
    ///
    /// Zero if the kernel will not say, which makes every holder look like it
    /// belongs to this boot. That is the safe direction: it can only make the
    /// lock more cautious about taking a hold over, never less.
    static func machineBootedAt() -> Int64 {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return Int64(boot.tv_sec) * 1000 + Int64(boot.tv_usec) / 1000
        #else
        return 0
        #endif
    }

    /// When a process started, in milliseconds since the epoch, or `nil` if
    /// the platform will not say for this one.
    ///
    /// **This is the case a boot instant cannot see**: a process id recycled
    /// within one boot, where the boot matches and the liveness check answers
    /// yes for something unrelated. Rare, and closed here only because Darwin
    /// will answer for a process this one does not own — which a portable
    /// interface will not, and which is why the kit this design was read from
    /// documents it as open rather than fixing it.
    ///
    /// `nil` rather than a sentinel, because "the platform declined" and "the
    /// process started at time zero" have to be different answers. A caller
    /// that gets `nil` falls back to the boot check, which is exactly where a
    /// portable implementation stops.
    static func processStartedAt(pid: Int32) -> Int64? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec != 0 else { return nil }
        return Int64(started.tv_sec) * 1000 + Int64(started.tv_usec) / 1000
        #else
        return nil
        #endif
    }
}
