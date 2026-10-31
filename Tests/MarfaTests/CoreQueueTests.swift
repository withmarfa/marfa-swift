import Foundation
import MarfaCore
import Synchronization
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct ACoreQueue {
    /// How many jobs run at once, and the most that did.
    final class Load: Sendable {
        private let counts = Mutex((now: 0, most: 0))
        var most: Int { counts.withLock { $0.most } }

        func enter() {
            counts.withLock {
                $0.now += 1
                $0.most = max($0.most, $0.now)
            }
        }

        func leave() { counts.withLock { $0.now -= 1 } }
    }

    @Test func neverRunsMoreJobsAtOnceThanItsLimit() async throws {
        let queue = CoreQueue(limit: 3)
        let load = Load()
        let finished = try await withThrowingTaskGroup(of: Int.self) { group in
            for number in 0..<60 {
                group.addTask {
                    try await queue.run {
                        load.enter()
                        defer { load.leave() }
                        Thread.sleep(forTimeInterval: 0.002)
                        return number
                    }
                }
            }
            var count = 0
            for try await _ in group { count += 1 }
            return count
        }
        #expect(finished == 60)
        #expect(load.most >= 1 && load.most <= 3, "\(load.most) jobs ran at once")
    }

    @Test func runsJobsUpToItsLimitTogether() async throws {
        let queue = CoreQueue(limit: 3)
        let arrived = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        let jobs = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<3 {
                    group.addTask {
                        try await queue.run {
                            arrived.withLock { $0 += 1 }
                            release.wait()
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        try await eventually("three jobs at once") { arrived.withLock { $0 } == 3 }
        for _ in 0..<3 { release.signal() }
        try await jobs.value
    }

    @Test func startsTheHighestPriorityWaitingJobFirst() async throws {
        let queue = CoreQueue(limit: 1)
        let hold = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        let order = Mutex<[String]>([])
        let blocker = Task {
            try await queue.run {
                started.withLock { $0 = true }
                hold.wait()
            }
        }
        try await eventually("the blocker started") { started.withLock { $0 } }
        func waiting(_ name: String, _ priority: TaskPriority) -> Task<Void, any Error> {
            Task(priority: priority) { try await queue.run { order.withLock { $0.append(name) } } }
        }
        let background = waiting("background", .background)
        try await eventually("the first waits") { queue.waitingCount == 1 }
        let high = waiting("high", .high)
        try await eventually("the second waits") { queue.waitingCount == 2 }
        let medium = waiting("medium", .medium)
        try await eventually("the third waits") { queue.waitingCount == 3 }
        let mediumLater = waiting("medium later", .medium)
        try await eventually("the fourth waits") { queue.waitingCount == 4 }
        hold.signal()
        for task in [blocker, background, high, medium, mediumLater] { try await task.value }
        #expect(order.withLock { $0 } == ["high", "medium", "medium later", "background"])
    }

    @Test(arguments: [
        (TaskPriority.high, DispatchQoS.QoSClass.userInitiated),
        (.medium, .default),
        (.low, .utility),
        (.background, .utility),
    ])
    func runsAJobAtTheQualityOfServiceOfTheTaskThatAskedNeverBelowUtility(
        priority: TaskPriority, expected: DispatchQoS.QoSClass
    )
        async throws
    {
        let queue = CoreQueue(limit: 2)
        let ran = Mutex<qos_class_t?>(nil)
        // Awaiting the task would raise its priority to the test's, so its answer is polled for.
        Task(priority: priority) {
            let qos = try await queue.run { qos_class_self() }
            ran.withLock { $0 = qos }
        }
        try await eventually("the job ran") { ran.withLock { $0 } != nil }
        #expect(ran.withLock { $0 } == expected.rawValue)
    }

    @Test func translatesTheCoresErrorsAndReturnsWhatTheWorkReturns() async throws {
        let queue = CoreQueue(limit: 1)
        #expect(try await queue.run { 7 } == 7)
        await #expect(throws: Marfa.MarfaError.self) {
            try await queue.run { throw MarfaCore.MarfaError.Network(message: "offline") as any Error }
        }
        #expect(try await queue.run { 8 } == 8)
    }

    @Test func theSharedQueuesAreBoundedAndApart() {
        #expect(CoreQueue.calls !== CoreQueue.blocking)
        #expect(CoreQueue.calls.limit >= 4 && CoreQueue.blocking.limit >= 8)
    }

    @Test func aJobCanceledWhileItWaitsLeavesTheQueueAndThrowsCanceled() async throws {
        let queue = CoreQueue(limit: 1)
        let hold = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        let ran = Mutex(false)
        let blocker = Task {
            try await queue.run {
                started.withLock { $0 = true }
                hold.wait()
            }
        }
        try await eventually("the blocker started") { started.withLock { $0 } }
        let waiting = Task { try await queue.run { ran.withLock { $0 = true } } }
        try await eventually("the job waits") { queue.waitingCount == 1 }
        waiting.cancel()
        await #expect { try await bounded("the canceled job", within: 10) { try await waiting.value } } throws: {
            error in
            if case Marfa.MarfaError.canceled = error { true } else { false }
        }
        #expect(queue.waitingCount == 0)
        hold.signal()
        try await blocker.value
        #expect(try await queue.run { 1 } == 1)
        #expect(!ran.withLock { $0 })
    }

    @Test func aTaskCanceledBeforeItAsksDoesNotRunEvenWithRoomFree() async throws {
        let queue = CoreQueue(limit: 2)
        let ran = Mutex(false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await queue.run { ran.withLock { $0 = true } }
        }
        await #expect { try await task.value } throws: { error in
            if case Marfa.MarfaError.canceled = error { true } else { false }
        }
        #expect(!ran.withLock { $0 })
        #expect(queue.waitingCount == 0)
    }

    @Test func workThatMustFinishRunsEvenForACanceledTask() async throws {
        let ran = Mutex(false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await background { ran.withLock { $0 = true } }
        }
        try await task.value
        #expect(ran.withLock { $0 })
    }

    @Test func cancelingAtAnyMomentResumesEveryCallerOnce() async throws {
        let queue = CoreQueue(limit: 2)
        let outcomes = try await withThrowingTaskGroup(of: Bool.self) { group in
            for number in 0..<200 {
                group.addTask {
                    let task = Task { try await queue.run { Thread.sleep(forTimeInterval: 0.0005) } }
                    if number % 2 == 0 { task.cancel() }
                    do {
                        try await task.value
                        return true
                    } catch Marfa.MarfaError.canceled {
                        return false
                    }
                }
            }
            var done = 0
            for try await _ in group { done += 1 }
            return done
        }
        #expect(outcomes == 200)
        #expect(queue.waitingCount == 0)
    }
}

@Suite(.timeLimit(.minutes(1)), .serialized)
struct CallsThatWaitOnTheServer {
    @Test func aSlowBlockingJobDoesNotDelayACall() async throws {
        let hold = DispatchSemaphore(value: 0)
        let running = Mutex(0)
        let slow = CoreQueue.blocking.limit
        let jobs = (0..<slow).map { _ in
            Task {
                try await CoreQueue.blocking.run {
                    running.withLock { $0 += 1 }
                    hold.wait()
                }
            }
        }
        defer { for _ in 0..<slow { hold.signal() } }
        try await eventually("the blocking lane is full") { running.withLock { $0 } == slow }
        #expect(
            try await bounded("a call beside a full blocking lane", within: 10) { try await CoreQueue.calls.run { 5 } }
                == 5)
        for _ in 0..<slow { hold.signal() }
        for job in jobs { try await job.value }
    }

    @Test(arguments: ["pin", "bin", "purge", "withFile"])
    func doNotHoldUpTheCoresOtherCalls(operation: String) async throws {
        let core = FakeCore.writer()
        let gate = core.holdNetwork()
        let copy = WorkingCopy(holder: CoreHolder(core), hasServer: true)
        let count = CoreQueue.calls.limit + 2
        let calls = (0..<count).map { _ in
            Task {
                switch operation {
                case "pin": _ = try await copy.pin("a")
                case "bin": _ = try await copy.items.bin()
                case "purge": try await copy.items.purge("a", version: 1)
                default: try await copy.blobs.withFile("h") { _ in }
                }
            }
        }
        defer { for _ in 0..<count { gate.signal() } }
        try await eventually("a call is waiting on the server") { core.networkCalls >= 1 }
        _ = try await bounded("a status read beside \(count) slow \(operation) calls", within: 10) {
            try await copy.status()
        }
        for _ in 0..<count { gate.signal() }
        for call in calls { _ = await call.result }
        await copy.close()
    }
}
