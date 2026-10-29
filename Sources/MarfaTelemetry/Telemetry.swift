import Foundation
import Marfa
import Synchronization

struct PendingException: Sendable {
    let type: String
    let sentence: String
    let code: String?
    let operation: String
}

struct PendingLog: Sendable {
    let name: String
    let level: Telemetry.LogLevel
    let attributes: [(name: String, value: Telemetry.LogAttribute.Value)]
    let nanoseconds: UInt64
}

/// Sends an app's errors and a fixed set of log events to a PostHog project.
///
/// Nothing is sent until the app calls ``configure(_:)`` with a destination of its own and then sets
/// ``isEnabled``; the package ships neither a destination nor a token. An app that does not import
/// `MarfaTelemetry` carries none of this.
///
/// What may be passed is limited by the types: an error is described by text fixed in the source
/// (``report(_:during:)``), and a log record carries a `StaticString` name and numbers, booleans or
/// `StaticString`s. Never pass, or find a way around the types to pass, item text, titles, tags, item ids,
/// natural keys, keys or credentials, the server's address, file paths, search text, or an error's `message` or
/// `localizedDescription`: each can hold a person's words.
///
/// Every call returns at once and does its work on a background task. A report that fails to send is lost and is
/// not retried.
public final class Telemetry: Sendable {
    /// The reporter an app configures once and calls from anywhere.
    public static let shared = Telemetry(transport: URLSessionTransport())

    static let batchSize = 50
    static let queueLimit = 500
    static let exceptionLimit = 20

    private struct State {
        var configuration: Configuration?
        var enabled = false
        var exceptions: [PendingException] = []
        var logs: [PendingLog] = []
        var dropped = 0
        var drain: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var generation = 0
    }

    private let state = Mutex(State())
    private let transport: any TelemetryTransport
    private let interval: Duration
    private let distinctID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    package init(transport: any TelemetryTransport, interval: Duration = .seconds(30)) {
        self.transport = transport
        self.interval = interval
    }

    /// Sets who is reporting and where to.
    ///
    /// It drops anything queued for an earlier configuration and sends nothing by itself. It leaves ``isEnabled``
    /// as it was, which is off until the app turns it on.
    public func configure(_ configuration: Configuration) {
        state.withLock { state in
            clear(&state)
            state.configuration = configuration
        }
    }

    /// Whether reports are sent.
    ///
    /// It is off until the app turns it on, and the app can change it at any time. Turning it off drops everything queued, stops a send under way, and sends nothing more.
    public var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set {
            state.withLock { state in
                if !newValue { clear(&state) }
                state.enabled = newValue
            }
        }
    }

    /// Reports a failure as one `$exception` event: the error's fixed type and sentence (``FixedErrorText``),
    /// never its message or any value it carries, and the operation that was running.
    ///
    /// - Parameters:
    ///   - error: The error to describe.
    ///   - operation: What the app was doing, such as `"drain"`. Fixed in the source.
    public func report(_ error: MarfaError, during operation: StaticString) {
        let text = error.fixedText
        enqueue(PendingException(type: text.type, sentence: text.sentence, code: text.code, operation: "\(operation)"))
    }

    /// Reports a failure of the app's own as one `$exception` event.
    ///
    /// - Parameters:
    ///   - type: A name for the kind of failure, such as `"editor_process_ended"`. Fixed in the source.
    ///   - sentence: One sentence that says what went wrong, with no value in it. Fixed in the source.
    ///   - operation: What the app was doing. Fixed in the source.
    public func report(type: StaticString, sentence: StaticString, during operation: StaticString) {
        enqueue(PendingException(type: "\(type)", sentence: "\(sentence)", code: nil, operation: "\(operation)"))
    }

    /// Queues a log record.
    ///
    /// Records are sent in batches of 50, or after 30 seconds, or by ``flush(deadline:)``.
    /// At most 500 wait; beyond that the oldest is dropped, and the next batch says how many were.
    ///
    /// - Parameters:
    ///   - name: What happened, such as `"drain_finished"`. Fixed in the source.
    ///   - level: How serious it is.
    ///   - attributes: Numbers, booleans and words fixed in the source. See ``LogAttribute``.
    public func log(
        _ name: StaticString, level: LogLevel = .info, attributes: KeyValuePairs<StaticString, LogAttribute> = [:]
    ) {
        let record = PendingLog(
            name: "\(name)", level: level, attributes: attributes.map { ("\($0.key)", $0.value.value) },
            nanoseconds: UInt64(max(0, Date.now.timeIntervalSince1970) * 1_000_000_000))
        var send = false
        var start = false
        state.withLock { state in
            guard state.enabled, state.configuration != nil else { return }
            if state.logs.count >= Self.queueLimit {
                state.logs.removeFirst()
                state.dropped += 1
            }
            state.logs.append(record)
            if state.logs.count >= Self.batchSize {
                send = true
            } else if state.timer == nil {
                start = true
            }
        }
        if send { startDrain() } else if start { startTimer() }
    }

    /// Sends what is queued and waits for it, up to `deadline`, then gives up on what has not finished.
    ///
    /// Call it when the app quits.
    public func flush(deadline: Duration = .seconds(2)) async {
        startDrain()
        guard let drain = state.withLock({ $0.drain }) else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await drain.value }
            group.addTask {
                try? await Task.sleep(for: deadline)
                drain.cancel()
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func enqueue(_ exception: PendingException) {
        let queued = state.withLock { state in
            guard state.enabled, state.configuration != nil, state.exceptions.count < Self.exceptionLimit else {
                return false
            }
            state.exceptions.append(exception)
            return true
        }
        if queued { startDrain() }
    }

    private func clear(_ state: inout State) {
        state.drain?.cancel()
        state.timer?.cancel()
        state.drain = nil
        state.timer = nil
        state.exceptions = []
        state.logs = []
        state.dropped = 0
        state.generation += 1
    }

    private func startTimer() {
        let interval = interval
        state.withLock { locked in
            guard locked.enabled, locked.timer == nil else { return }
            let generation = locked.generation
            locked.timer = Task.detached(priority: .utility) { [self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                let current = state.withLock { state in
                    guard state.generation == generation else { return false }
                    state.timer = nil
                    return true
                }
                if current { startDrain() }
            }
        }
    }

    private func startDrain() {
        state.withLock { state in
            guard state.enabled, state.drain == nil,
                !state.exceptions.isEmpty || !state.logs.isEmpty
            else { return }
            let generation = state.generation
            state.drain = Task.detached(priority: .utility) { [self] in await drain(generation) }
        }
    }

    private enum Work {
        case exception(PendingException, Configuration)
        case logs([PendingLog], dropped: Int, Configuration)
    }

    private func next(_ generation: Int) -> Work? {
        state.withLock { state in
            guard state.generation == generation, state.enabled, let configuration = state.configuration else {
                return nil
            }
            if !state.exceptions.isEmpty {
                return .exception(state.exceptions.removeFirst(), configuration)
            }
            if !state.logs.isEmpty {
                let work = Work.logs(state.logs, dropped: state.dropped, configuration)
                state.logs = []
                state.dropped = 0
                return work
            }
            state.drain = nil
            return nil
        }
    }

    private func drain(_ generation: Int) async {
        while !Task.isCancelled, let work = next(generation) {
            let request: TelemetryRequest?
            switch work {
            case .exception(let exception, let configuration):
                request = Wire.exception(exception, context(configuration))
            case .logs(let records, let dropped, let configuration):
                request = Wire.logs(records, dropped: dropped, context(configuration))
            }
            if let request { await transport.send(request) }
        }
        // An empty queue was cleared by `next`. A stop leaves the handle for this to clear, and only this
        // task's own, since no other drain starts while it is set.
        if Task.isCancelled {
            state.withLock { state in
                if state.generation == generation { state.drain = nil }
            }
        }
    }

    private func context(_ configuration: Configuration) -> Wire.Context {
        Wire.Context(
            configuration: configuration, instanceID: configuration.instanceID?(), distinctID: distinctID)
    }
}
