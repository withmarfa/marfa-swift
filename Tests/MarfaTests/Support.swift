import Foundation
import MarfaCore
import Network
import Synchronization
import Testing

@testable import Marfa

func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "marfa-\(UUID()).sqlite")
}

func eventually(_ what: String, within seconds: Double = 5, _ condition: () async throws -> Bool) async throws {
    let deadline = Date.now.addingTimeInterval(seconds)
    while try await !condition() {
        guard Date.now < deadline else {
            Issue.record("never: \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

struct Unfinished: Error, CustomStringConvertible {
    let what: String
    var description: String { "\(what) did not finish" }
}

/// A suite's time limit cancels a test, and cancellation cannot end an
/// await that ignores it, such as a task's value or a continuation nobody
/// resumes: a test waiting on one would hang past its limit.
func bounded<T: Sendable>(
    _ what: String, within seconds: Double = 10, _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let answer = Answer(continuation)
        let job = Job(work)
        Task { answer.resume(with: await job.run()) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            answer.resume(with: .failure(Unfinished(what: what)))
        }
    }
}

/// Releases the work before answering, so a caller that then drops a working
/// copy finds nothing else holding its store.
private final class Job<T: Sendable>: Sendable {
    private let work: Mutex<(@Sendable () async throws -> T)?>

    init(_ work: @escaping @Sendable () async throws -> T) {
        self.work = Mutex(work)
    }

    func run() async -> Result<T, any Error> {
        guard let work = self.work.withLock({ $0.take() }) else {
            preconditionFailure("a job runs once")
        }
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }
}

private final class Answer<T: Sendable>: Sendable {
    private let waiting: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        waiting = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        waiting.withLock { $0.take() }?.resume(with: result)
    }
}

final class Heard: Sendable {
    private final class Log: Sendable {
        let entries = Mutex<[(at: Date, change: Marfa.Change)]>([])
    }

    private let log: Log
    private let listening: Task<Void, Never>

    init(_ stream: AsyncStream<Marfa.Change>) {
        let log = Log()
        self.log = log
        listening = Task {
            for await change in stream {
                log.entries.withLock { $0.append((.now, change)) }
            }
        }
    }

    var all: [Marfa.Change] { log.entries.withLock { $0.map(\.change) } }
    var timed: [(at: Date, change: Marfa.Change)] { log.entries.withLock { $0 } }

    var locals: [Marfa.Change] {
        all.filter { if case .local = $0.origin { true } else { false } }
    }

    var saves: [(at: Date, change: Marfa.Change)] {
        timed.filter { if case .saved = $0.change.origin { true } else { false } }
    }

    var stops: [Marfa.Change] {
        all.filter { if case .stopped = $0.origin { true } else { false } }
    }

    func stop() {
        listening.cancel()
    }
}

/// For what a real core cannot be made to do on cue.
///
/// A follow that ends late, fails, or speaks after it was replaced. It keeps
/// the core's rules: one stream at a time, let go only as the follow ends,
/// `ended` told a moment after `stop`, and hydration and catch-up refused
/// while a follow holds the stream.
final class FakeCore: Core, @unchecked Sendable {
    struct Follow {
        let listener: any MarfaCore.ChangeListener
        let holdsStream: Bool
        var stopped = false
        var ended = false
    }

    struct State {
        var handle = MarfaCore.Handle.writer
        var follows: [Follow] = []
        var streamHeld = false
        var caughtUp = MarfaCore.CatchUpReport(applied: 0, skipped: 0, cursor: "1", reachedHead: true)
        var drained = MarfaCore.DrainReport(
            answered: 0, held: 0, undelivered: 0, unsent: 0, unmade: 0, unavailable: nil, verdicts: [], stopped: nil,
            unclaimedSources: [], retryAfterSeconds: nil)
        var dataVersion: Int64 = 0
        var gate: DispatchSemaphore?
        var gated = false
        var readsFail: MarfaCore.MarfaError?
        var withdrawable: Set<String> = []
        var catalogVersion: UInt64? = 1
        var catchUpChangesCatalog = false
        var catchUpFails: MarfaCore.MarfaError?
        var declarations: [String] = []
        var registrationRefusals: [MarfaCore.UnregisteredType] = []
        var hydrationOptions: (types: [String], tier: MarfaCore.Tier, edgeTypes: [String])?
        var pins: Set<String> = []
        var probe: DropProbe?
    }

    let state = Mutex(State())

    static func reader() -> FakeCore {
        let core = FakeCore(noHandle: .init())
        core.state.withLock { $0.handle = .reader }
        return core
    }

    static func writer() -> FakeCore {
        FakeCore(noHandle: .init())
    }

    /// A writer whose drop waits on `probe`, to hold a close in the middle of
    /// releasing the store.
    static func writer(probe: DropProbe) -> FakeCore {
        let core = FakeCore(noHandle: .init())
        core.state.withLock { $0.probe = probe }
        return core
    }

    deinit {
        guard let probe = state.withLock({ $0.probe }) else { return }
        probe.begin()
        probe.gate.wait()
    }

    var follows: [Follow] { state.withLock { $0.follows } }

    override func heldHandle() -> MarfaCore.Handle {
        state.withLock { $0.handle }
    }

    override func follow(listener: any MarfaCore.ChangeListener) -> MarfaCore.Subscription {
        let (index, refused) = state.withLock { state in
            let refused = state.streamHeld
            state.follows.append(Follow(listener: listener, holdsStream: !refused))
            state.streamHeld = true
            return (state.follows.count - 1, refused)
        }
        if refused {
            later {
                self.end(index, with: .Invalid(message: Self.refusal))
            }
        }
        return FakeSubscription { [self] in
            state.withLock { $0.follows[index].stopped = true }
            later { self.end(index, with: nil) }
        }
    }

    func fail(_ index: Int, with error: MarfaCore.MarfaError) {
        end(index, with: error)
    }

    /// No real core ends a follow twice; the feed must ignore it.
    func endAgain(_ index: Int, with error: MarfaCore.MarfaError?) {
        state.withLock { $0.follows[index].listener }.ended(error: error)
    }

    func change(_ index: Int, _ change: MarfaCore.Change) {
        state.withLock { $0.follows[index].listener }.changed(change: change)
    }

    override func hydrateWith(types: [String], tier: MarfaCore.Tier, edgeTypes: [String], stop: MarfaCore.Stop?) throws
        -> MarfaCore.HydrateReport
    {
        try refreshing()
        state.withLock { $0.hydrationOptions = (types, tier, edgeTypes) }
        return MarfaCore.HydrateReport(
            types: types, tier: tier, edgeTypes: edgeTypes, items: 0, edges: 0, pages: 1, cursor: "1",
            registeredTypes: [], unregisteredTypes: state.withLock { $0.registrationRefusals })
    }

    override func declareTypes(types: [String]) {
        state.withLock { $0.declarations = types }
    }

    override func declaredTypes() -> [String] {
        state.withLock { $0.declarations }
    }

    override func pin(id: String) throws -> MarfaCore.PinReport {
        let added = state.withLock { $0.pins.insert(id).inserted }
        return MarfaCore.PinReport(pinned: true, wasPinned: !added)
    }

    override func unpin(id: String) throws -> MarfaCore.PinReport {
        let removed = state.withLock { $0.pins.remove(id) != nil }
        return MarfaCore.PinReport(pinned: false, wasPinned: removed)
    }

    override func catchUp(stop: MarfaCore.Stop?) throws -> MarfaCore.CatchUpReport {
        try refreshing()
        return try state.withLock { state in
            if state.catchUpChangesCatalog { state.catalogVersion = (state.catalogVersion ?? 0) + 1 }
            if let failure = state.catchUpFails { throw failure }
            return state.caughtUp
        }
    }

    override func status() throws -> MarfaCore.Status {
        MarfaCore.Status(
            serverOrigin: nil, instanceId: nil, sliceTypes: [], sliceTier: nil, sliceEdgeTypes: [], pinned: [],
            eventCursor: nil,
            hydration: .complete, items: 0, edges: 0, catalogVersion: state.withLock { $0.catalogVersion })
    }

    override func withdraw(id: String) throws -> Bool {
        state.withLock { $0.withdrawable.remove(id) != nil }
    }

    override func drain(stop: MarfaCore.Stop?) throws -> MarfaCore.DrainReport {
        state.withLock { $0.drained }
    }

    override func dataVersion() throws -> Int64 {
        let gate = state.withLock { state in
            defer { state.gate = nil }
            state.gated = state.gate != nil
            return state.gate
        }
        gate?.wait()
        return try state.withLock { state in
            if let error = state.readsFail { throw error }
            return state.dataVersion
        }
    }

    func save() {
        state.withLock { $0.dataVersion += 1 }
    }

    func holdNextRead() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        state.withLock { $0.gate = gate }
        return gate
    }

    var aReadWasHeld: Bool { state.withLock { $0.gated } }

    static let refusal =
        "this working copy is already hydrating, catching up or following; one at a time moves its cursor"

    private func refreshing() throws {
        let held = state.withLock { $0.streamHeld }
        if held {
            throw MarfaCore.MarfaError.Invalid(message: Self.refusal)
        }
    }

    private func end(_ index: Int, with error: MarfaCore.MarfaError?) {
        let listener = state.withLock { state -> (any MarfaCore.ChangeListener)? in
            guard !state.follows[index].ended else { return nil }
            state.follows[index].ended = true
            if state.follows[index].holdsStream { state.streamHeld = false }
            return state.follows[index].listener
        }
        listener?.ended(error: error)
    }

    private func later(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }
}

/// Lets a test see a core being dropped and hold the drop.
final class DropProbe: Sendable {
    private let started = Mutex(false)
    let gate = DispatchSemaphore(value: 0)

    var hasStarted: Bool { started.withLock { $0 } }

    func begin() {
        started.withLock { $0 = true }
    }
}

final class FakeSubscription: MarfaCore.Subscription, @unchecked Sendable {
    private let onStop: @Sendable () -> Void

    init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("a fake subscription has no handle")
    }

    override func stop() {
        onStop()
    }
}

func write(_ kind: Marfa.WriteKind, item: String?, target: String? = nil, edge: String? = nil) -> Marfa.QueuedWrite {
    Marfa.QueuedWrite(
        id: "q-\(UUID())", kind: kind, itemId: item, targetId: target, edgeId: edge, namespace: nil, tag: nil,
        blob: nil, baseVersion: nil, idempotencyKey: "k", dependsOn: [], follows: nil, verdict: nil, answer: nil,
        refusals: 0, queuedAt: "", answeredAt: nil)
}

/// A server on a local port answering each request by its method and path.
///
/// Every answer names `contract`.
struct LocalServer: Sendable {
    static let readView = String(repeating: "a", count: 64)
    typealias Answer = (status: Int, type: String, body: String)

    let url: URL
    let listener: NWListener
    /// The head of each request received, in order.
    let log: RequestLog

    final class RequestLog: Sendable {
        let heads = Mutex<[String]>([])
        let connections = Mutex<[NWConnection]>([])
        var all: [String] { heads.withLock { $0 } }
    }

    static func emptyPage(_ method: String, _ path: String) -> Answer {
        if path == "/" {
            return (200, "application/json", #"{"instance_id":"test-instance"}"#)
        }
        return (200, "application/json", #"{"data":[],"next_cursor":null}"#)
    }

    static func start(
        contract: Int,
        headers: String = "x-marfa-read-view: \(LocalServer.readView)\r\ncache-control: no-store\r\n",
        holdsResponse: Bool = false,
        answer: @escaping @Sendable (_ method: String, _ path: String) -> Answer = emptyPage
    ) async throws -> LocalServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let log = RequestLog()
        listener.newConnectionHandler = { connection in
            log.connections.withLock { $0.append(connection) }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                log.heads.withLock { $0.append(head) }
                let line = head.prefix { $0 != "\r" }.split(separator: " ")
                let method = line.first.map(String.init) ?? ""
                let path = line.dropFirst().first.map { String($0.split(separator: "?").first ?? "") } ?? ""
                if holdsResponse { return }
                let (status, type, body) = answer(method, path)
                let response = Data(
                    ("HTTP/1.1 \(status) Answered\r\ncontent-type: \(type)\r\nx-marfa-contract: \(contract)\r\n"
                        + headers + "content-length: \(body.utf8.count)\r\nconnection: close\r\n\r\n\(body)").utf8)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)"))
        return LocalServer(url: url, listener: listener, log: log)
    }

    func stop() {
        listener.cancel()
        for connection in log.connections.withLock({ $0 }) { connection.cancel() }
    }
}

/// A server of a test's own, booted with marfa's `core/scripts/server-up.sh`
/// from the checkout `MARFA_MONOREPO` names, so a test can stop it and start
/// it again under a copy.
///
/// Started again, it keeps its port, data and keys.
final class OwnServer: Sendable {
    static let monorepo = ProcessInfo.processInfo.environment["MARFA_MONOREPO"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
    }

    let state: URL
    let url: URL
    let key: String
    var server: Server { Server(url: url, key: key) }
    private var env: URL { state.appending(path: "env") }

    private init(state: URL, url: URL, key: String) {
        self.state = state
        self.url = url
        self.key = key
    }

    static func boot() async throws -> OwnServer {
        let state = FileManager.default.temporaryDirectory.appending(path: "marfa-own-server-\(UUID())")
        let exports = try await up(state)
        let url = try #require(exports["MARFA_TEST_URL"].flatMap(URL.init(string:)))
        return OwnServer(state: state, url: url, key: try #require(exports["MARFA_TEST_KEY"]))
    }

    func stop() async throws {
        _ = try await Self.script("server-down.sh", [env.path], keep: state)
    }

    func start() async throws {
        let exports = try await Self.up(state)
        try #require(exports["MARFA_TEST_URL"] == url.absoluteString, "the server came back at another address")
    }

    /// Stops it and takes its state away.
    func end() async throws {
        try await stop()
        try? FileManager.default.removeItem(at: state)
    }

    private static func up(_ state: URL) async throws -> [String: String] {
        let printed = try await script("server-up.sh", [], keep: state)
        var exports: [String: String] = [:]
        for line in printed.split(separator: "\n") where line.hasPrefix("export ") {
            let pair = line.dropFirst("export ".count).split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            exports[String(pair[0])] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        }
        return exports
    }

    private static func script(_ name: String, _ arguments: [String], keep: URL) async throws -> String {
        let monorepo = try #require(monorepo, "MARFA_MONOREPO names no checkout")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [monorepo.appending(path: "core/scripts/\(name)").path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["MARFA_SERVER_KEEP"] = keep.path
        environment["MARFA_SERVER_ENV"] = keep.appending(path: "env").path
        environment.removeValue(forKey: "PORT")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let ended = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        var status: Int32 = -1
        for await code in ended { status = code }
        try #require(status == 0, "\(name) exited \(status)")
        return String(decoding: printed, as: UTF8.self)
    }
}
