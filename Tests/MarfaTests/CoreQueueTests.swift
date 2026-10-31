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
        (.background, .background),
    ])
    func runsAJobAtTheQualityOfServiceOfTheTaskThatAsked(priority: TaskPriority, expected: DispatchQoS.QoSClass)
        async throws
    {
        let queue = CoreQueue(limit: 2)
        let ran = try await Task(priority: priority) {
            try await queue.run { qos_class_self() }
        }.value
        #expect(ran == expected.rawValue)
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
}
