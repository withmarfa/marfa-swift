import Foundation
import MarfaCore
import Network
import Synchronization
import Testing

@testable import Marfa

func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "marfa-\(UUID()).sqlite")
}

/// Waits for `condition`, and returns the moment it holds, so `seconds` only bounds a failure.
///
/// The default is far beyond what a test needs: with every test running at once, threads blocked on the store
/// stall the whole process for ten seconds or more on a loaded machine, and a shorter bound fails with nothing
/// wrong. A test that checks promptness sets a shorter `seconds` itself.
func eventually(
    _ what: String, within seconds: Double = 30, isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async throws {
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
    _ what: String, within seconds: Double = 30, _ work: @escaping @Sendable () async throws -> T
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
/// A watch that ends late, ends on a fault, or speaks after the listener was
/// replaced. It keeps the core's rules: a listener is told `ended` a moment
/// after `stop`, and once.
final class FakeCore: Core, @unchecked Sendable {
    struct Place {
        let listener: any MarfaCore.ChangeListener
        let toldUnreachable: Bool
        var stopped = false
        var ended = false
    }

    struct State {
        var handle = MarfaCore.Handle.writer
        var places: [Place] = []
        var watchRefused: MarfaCore.MarfaError?
        var caughtUp = MarfaCore.CatchUpReport(applied: 0, skipped: 0, cursor: "1", catalogChanged: false)
        var drained = MarfaCore.DrainReport(
            answered: 0, held: 0, undelivered: 0, unsent: 0, unmade: 0, unavailable: nil, verdicts: [], stopped: nil,
            unclaimedSources: [], retryAfterSeconds: nil)
        var dataVersion: Int64 = 0
        var gate: DispatchSemaphore?
        var gated = false
        var watchGate: DispatchSemaphore?
        var watchGated = false
        var withdrawable: Set<String> = []
        var answered: Set<String> = []
        var refused: Set<String> = []
        var catchUpChangesCatalog = false
        var catchUpFails: MarfaCore.MarfaError?
        /// What each next catch-up does before `catchUpFails` applies, in order: it waits for `hold` to be
        /// signaled, and fails with `fails` where one is given.
        var catchUpScript: [(hold: DispatchSemaphore?, fails: MarfaCore.MarfaError?)] = []
        var catchUps = 0
        /// Held by the next `status()` after it has read the copy, so it answers what the copy was when it began.
        var statusGate: DispatchSemaphore?
        /// How many held `status()` reads have returned.
        var heldStatuses = 0
        var drains = 0
        /// While a hydration runs, what `status()` says of its progress.
        var itemsExpected: UInt64?
        var itemsListed: UInt64?
        /// What `status()` says of when the copy last synced; a catch-up that succeeds sets it to `pullsAt`.
        var syncedAt: String?
        var pullsAt: String?
        /// Each item a server event named, in order, which `changesSince` answers from.
        var changedItems: [String] = []
        var hydrateFails: MarfaCore.MarfaError?
        var hydrateInPlace = false
        var hydration = MarfaCore.Hydration.complete
        var edgeWriteFails: MarfaCore.MarfaError?
        var declarations: [MarfaCore.JsonObject] = []
        var registrationRefusals: [MarfaCore.UnregisteredType] = []
        var replacedTypes: [String] = []
        var replacementRefusals: [MarfaCore.UnregisteredType] = []
        var hydrationOptions: (types: [String], tier: MarfaCore.SliceTier, edgeTypes: [String])?
        var slice: (types: [String], tier: MarfaCore.SliceTier, edgeTypes: [String])?
        /// When each hydration began.
        var hydrations: [[String]] = []
        /// Whether each hydration asked to fill in place only, in order.
        var hydrationsInPlaceOnly: [Bool] = []
        /// Fails this many hydrations with `hydrateFails` before the rest succeed; `nil` fails them all.
        var hydrateFailsFirst: Int?
        /// Held by the next hydration until signaled, as `gate` holds a drain.
        var hydrateGate: DispatchSemaphore?
        var hydrateGated = false
        var hydrating = false
        /// A completed hydration leaves the copy `.complete`, as the core's does.
        var hydrationCompletes = false
        var instanceId: String?
        var serverOrigin: String?
        var pins: Set<String> = []
        /// Held by every call that goes to the server until signaled, once `holdNetwork()` sets it.
        var networkGate: DispatchSemaphore?
        var networkCalls = 0
        var probe: DropProbe?
        var budgets: [MarfaCore.FileBudget] = []
        var trimmed: UInt64 = 0
        var keptFetches = 0
        var cache = MarfaCore.FileCache(
            setting: .default, budget: nil, held: nil, heldUnreadable: nil, volumeUnreadable: false,
            backupMarkFailure: nil, attachments: nil)
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

    /// Every place a listener took in the watch, in order.
    var places: [Place] { state.withLock { $0.places } }

    override func heldHandle() -> MarfaCore.Handle {
        state.withLock { $0.handle }
    }

    override func watch(toldUnreachable: Bool, listener: any MarfaCore.ChangeListener) throws -> MarfaCore.Subscription
    {
        let held = state.withLock { state in
            defer { state.watchGate = nil }
            state.watchGated = state.watchGate != nil
            return state.watchGate
        }
        held?.wait()
        let (index, refused) = state.withLock { state in
            if state.watchRefused == nil {
                state.places.append(Place(listener: listener, toldUnreachable: toldUnreachable))
            }
            return (state.places.count - 1, state.watchRefused)
        }
        if let refused { throw refused }
        return FakeSubscription { [self] in
            state.withLock { $0.places[index].stopped = true }
            later { self.end(index, with: nil) }
        }
    }

    /// The core ends the listener on a fault of its own.
    func fail(_ index: Int, with error: MarfaCore.MarfaError) {
        end(index, with: error)
    }

    /// No real core ends a listener twice; the feed must ignore it.
    func endAgain(_ index: Int, with error: MarfaCore.MarfaError?) {
        state.withLock { $0.places[index].listener }.ended(error: error)
    }

    func change(_ index: Int, _ change: MarfaCore.Change) {
        let listener = state.withLock { state in
            if case .applied(_, let itemId?, _, _) = change { state.changedItems.append(itemId) }
            return state.places[index].listener
        }
        listener.changed(change: change)
    }

    /// Names the items server events named since `cursor`, a count of them, as the core's change log does.
    override func changesSince(cursor: String?, most: UInt32) throws -> MarfaCore.CopyChanges {
        let changed = state.withLock { $0.changedItems }
        let next = String(changed.count)
        guard let cursor, let start = Int(cursor), start <= changed.count else {
            return MarfaCore.CopyChanges(
                cursor: next, everything: true, items: [], removedItems: [], edges: [], removedEdges: [])
        }
        var items: [String] = []
        var seen: Set<String> = []
        for id in changed[start...] where seen.insert(id).inserted { items.append(id) }
        guard items.count <= Int(most) else {
            return MarfaCore.CopyChanges(
                cursor: next, everything: true, items: [], removedItems: [], edges: [], removedEdges: [])
        }
        return MarfaCore.CopyChanges(
            cursor: next, everything: false, items: items, removedItems: [], edges: [], removedEdges: [])
    }

    override func hydrateWith(
        types: [String], tier: MarfaCore.SliceTier, edgeTypes: [String], inPlaceOnly: Bool, stop: MarfaCore.Stop?
    ) throws
        -> MarfaCore.HydrateReport
    {
        // The core holds one hydration at a time (`claim_stream(Mover::Hydration)`).
        let held = try state.withLock { state -> DispatchSemaphore? in
            guard !state.hydrating else {
                throw MarfaCore.MarfaError.Invalid(
                    message: "this working copy is already hydrating, catching up or following")
            }
            state.hydrating = true
            defer { state.hydrateGate = nil }
            state.hydrateGated = state.hydrateGate != nil
            return state.hydrateGate
        }
        defer { state.withLock { $0.hydrating = false } }
        let failure = state.withLock { state -> MarfaCore.MarfaError? in
            state.hydrationOptions = (types, tier, edgeTypes)
            state.hydrations.append(types)
            state.hydrationsInPlaceOnly.append(inPlaceOnly)
            guard let failure = state.hydrateFails else { return nil }
            guard let first = state.hydrateFailsFirst else { return failure }
            state.hydrateFailsFirst = first - 1
            return first > 0 ? failure : nil
        }
        held?.wait()
        if let failure { throw failure }
        state.withLock { state in
            if state.hydrationCompletes {
                state.hydration = .complete
                state.slice = (types, tier, edgeTypes)
            }
        }
        return MarfaCore.HydrateReport(
            types: types, tier: tier, edgeTypes: edgeTypes, items: 0, edges: 0, pages: 1, pagesTotal: 1, resumed: false,
            restarted: nil, inPlace: state.withLock { $0.hydrateInPlace }, cursor: "1", registeredTypes: [],
            unregisteredTypes: state.withLock { $0.registrationRefusals },
            replacedTypes: state.withLock { $0.replacedTypes },
            unreplacedTypes: state.withLock { $0.replacementRefusals })
    }

    override func setFileBudget(budget: MarfaCore.FileBudget) throws -> UInt64 {
        state.withLock { state in
            state.budgets.append(budget)
            state.cache.setting = budget
            return state.trimmed
        }
    }

    override func trimFiles() throws -> UInt64 {
        state.withLock { $0.trimmed }
    }

    override func fileCache() throws -> MarfaCore.FileCache {
        state.withLock { $0.cache }
    }

    override func fetchKept(stop: MarfaCore.Stop?) throws -> MarfaCore.KeptFetch {
        state.withLock { state in
            state.keptFetches += 1
            return MarfaCore.KeptFetch(fetched: 2, fetchedBytes: 30, attachments: state.cache.attachments)
        }
    }

    override func declareTypes(types: [MarfaCore.JsonObject]) {
        state.withLock { $0.declarations = types }
    }

    override func declaredTypes() -> [MarfaCore.JsonObject] {
        state.withLock { $0.declarations }
    }

    private func goToServer() {
        let gate = state.withLock { state in
            state.networkCalls += 1
            return state.networkGate
        }
        gate?.wait()
    }

    /// Makes `pin`, `bin`, `purgeItem` and `blob` wait for a signal, and the last three then fail with `network`.
    func holdNetwork() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        state.withLock { $0.networkGate = gate }
        return gate
    }

    var networkCalls: Int { state.withLock { $0.networkCalls } }

    override func bin(type: String?, cursor: String?, limit: UInt32) throws -> MarfaCore.BinPage {
        goToServer()
        throw MarfaCore.MarfaError.Network(message: "offline")
    }

    override func purgeItem(id: String, version: Int64?) throws {
        goToServer()
        throw MarfaCore.MarfaError.Network(message: "offline")
    }

    override func blob(hash: String) throws -> MarfaCore.BlobPath {
        goToServer()
        throw MarfaCore.MarfaError.Network(message: "offline")
    }

    override func pin(id: String) throws -> MarfaCore.PinReport {
        goToServer()
        let added = state.withLock { $0.pins.insert(id).inserted }
        return MarfaCore.PinReport(pinned: true, wasPinned: !added)
    }

    override func unpin(id: String) throws -> MarfaCore.PinReport {
        let removed = state.withLock { $0.pins.remove(id) != nil }
        return MarfaCore.PinReport(pinned: false, wasPinned: removed)
    }

    override func catchUp(stop: MarfaCore.Stop?) throws -> MarfaCore.CatchUpReport {
        let step = state.withLock { state in state.catchUpScript.isEmpty ? nil : state.catchUpScript.removeFirst() }
        step?.hold?.wait()
        if let failure = step?.fails {
            state.withLock { $0.catchUps += 1 }
            throw MarfaCore.CatchUpError.Failed(error: failure, catalogChanged: false)
        }
        return try state.withLock { state in
            // The core's catch-up claims the stream a hydration holds (`claim_stream(Mover::CatchUp)`).
            guard !state.hydrating else {
                throw MarfaCore.CatchUpError.Failed(
                    error: .Invalid(message: "this working copy is already hydrating, catching up or following"),
                    catalogChanged: false)
            }
            state.catchUps += 1
            if let failure = state.catchUpFails {
                throw MarfaCore.CatchUpError.Failed(error: failure, catalogChanged: state.catchUpChangesCatalog)
            }
            if let pullsAt = state.pullsAt { state.syncedAt = pullsAt }
            var report = state.caughtUp
            report.catalogChanged = state.catchUpChangesCatalog
            return report
        }
    }

    override func status() throws -> MarfaCore.Status {
        let (slice, origin, instance, hydration, held) = state.withLock { state in
            defer { state.statusGate = nil }
            return (state.slice, state.serverOrigin, state.instanceId, state.hydration, state.statusGate)
        }
        held?.wait()
        if held != nil { state.withLock { $0.heldStatuses += 1 } }
        return MarfaCore.Status(
            serverOrigin: origin, instanceId: instance, sliceTypes: slice?.types ?? [], sliceTier: slice?.tier,
            sliceEdgeTypes: slice?.edgeTypes ?? [], pinned: [],
            eventCursor: nil,
            hydration: hydration, items: 0, itemsExpected: state.withLock { $0.itemsExpected },
            itemsListed: state.withLock { $0.itemsListed }, edges: 0,
            catalogVersion: 1, syncedAt: state.withLock { $0.syncedAt },
            fileCache: MarfaCore.FileCache(
                setting: .default, budget: nil, held: nil, heldUnreadable: nil, volumeUnreadable: false,
                backupMarkFailure: nil, attachments: nil))
    }

    override func createEdge(draft: MarfaCore.EdgeDraft) throws -> MarfaCore.QueuedWrite {
        if let failure = state.withLock({ $0.edgeWriteFails }) { throw failure }
        return try super.createEdge(draft: draft)
    }

    override func withdraw(id: String) throws -> Bool {
        state.withLock { $0.withdrawable.remove(id) != nil }
    }

    override func forgetAnswered() throws -> UInt64 {
        state.withLock { state in
            defer { state.answered = [] }
            return UInt64(state.answered.count)
        }
    }

    override func forgetAnsweredIds(ids: [String]) throws -> UInt64 {
        state.withLock { state in
            let named = state.answered.intersection(ids)
            state.answered.subtract(named)
            return UInt64(named.count)
        }
    }

    override func discard(id: String) throws -> Bool {
        state.withLock { $0.refused.remove(id) != nil }
    }

    override func drain(stop: MarfaCore.Stop?) throws -> MarfaCore.DrainReport {
        state.withLock { state in
            state.drains += 1
            return state.drained
        }
    }

    override func dataVersion() throws -> Int64 {
        let gate = state.withLock { state in
            defer { state.gate = nil }
            state.gated = state.gate != nil
            return state.gate
        }
        gate?.wait()
        return state.withLock { $0.dataVersion }
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

    func holdNextWatch() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        state.withLock { $0.watchGate = gate }
        return gate
    }

    var aWatchWasHeld: Bool { state.withLock { $0.watchGated } }

    private func end(_ index: Int, with error: MarfaCore.MarfaError?) {
        let listener = state.withLock { state -> (any MarfaCore.ChangeListener)? in
            guard !state.places[index].ended else { return nil }
            state.places[index].ended = true
            return state.places[index].listener
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

/// What a core that records no changes answers a copy's updates: read everything, at one cursor.
func everythingChanged() -> MarfaCore.CopyChanges {
    MarfaCore.CopyChanges(cursor: "0", everything: true, items: [], removedItems: [], edges: [], removedEdges: [])
}

/// The status of an empty copy no hydration has filled, for a core that answers nothing else of it.
func emptyStatus() -> MarfaCore.Status {
    MarfaCore.Status(
        serverOrigin: nil, instanceId: nil, sliceTypes: [], sliceTier: nil, sliceEdgeTypes: [], pinned: [],
        eventCursor: nil, hydration: .never, items: 0, itemsExpected: nil, itemsListed: 0, edges: 0,
        catalogVersion: 1, syncedAt: nil,
        fileCache: MarfaCore.FileCache(
            setting: .default, budget: nil, held: nil, heldUnreadable: nil, volumeUnreadable: false,
            backupMarkFailure: nil, attachments: nil))
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
    static let reach = String(repeating: "a", count: 64)
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
        headers: String = "x-marfa-reach: \(LocalServer.reach)\r\ncache-control: no-store\r\n",
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

/// A TCP relay on a local port in front of a server, which a test cuts and mends as a Mac that sleeps or loses
/// its network does, while the server itself stays up for others.
final class Relay: Sendable {
    let url: URL
    private let listener: NWListener
    private let state = Mutex<(cut: Bool, open: [NWConnection])>((false, []))

    private init(url: URL, listener: NWListener) {
        self.url = url
        self.listener = listener
    }

    static func start(to target: URL) async throws -> Relay {
        let host = NWEndpoint.Host(try #require(target.host()))
        let number = try #require(target.port.flatMap { UInt16(exactly: $0) })
        let port = try #require(NWEndpoint.Port(rawValue: number))
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
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
            listener.newConnectionHandler = { _ in }
            listener.start(queue: .global())
        }
        let relay = Relay(url: try #require(URL(string: "http://127.0.0.1:\(ready)")), listener: listener)
        listener.newConnectionHandler = { [weak relay] inbound in
            guard let relay else { return inbound.forceCancel() }
            let outbound = NWConnection(host: host, port: port, using: .tcp)
            let admitted = relay.state.withLock { state -> Bool in
                guard !state.cut else { return false }
                state.open += [inbound, outbound]
                return true
            }
            guard admitted else { return inbound.forceCancel() }
            inbound.start(queue: .global())
            outbound.start(queue: .global())
            Self.pump(from: inbound, to: outbound)
            Self.pump(from: outbound, to: inbound)
        }
        return relay
    }

    private static func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { _ in })
            }
            if complete || error != nil {
                sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                return
            }
            pump(from: source, to: sink)
        }
    }

    /// Resets every connection through the relay and refuses new ones until ``mend()``.
    func cut() {
        let open = state.withLock { state in
            state.cut = true
            defer { state.open = [] }
            return state.open
        }
        for connection in open { connection.forceCancel() }
    }

    func mend() {
        state.withLock { $0.cut = false }
    }

    func stop() {
        cut()
        listener.cancel()
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
    /// The server's control socket, which serves the test hooks when the server was booted with them.
    let socket: String?
    let owner: (email: String, password: String)?
    private let testHooks: Bool
    var server: Server { Server(url: url, key: key) }
    private var env: URL { state.appending(path: "env") }

    private init(state: URL, exports: [String: String], testHooks: Bool) throws {
        self.state = state
        url = try #require(exports["MARFA_TEST_URL"].flatMap(URL.init(string:)))
        key = try #require(exports["MARFA_TEST_KEY"])
        socket = exports["MARFA_TEST_SOCKET"]
        owner = exports["MARFA_TEST_OWNER_EMAIL"].flatMap { email in
            exports["MARFA_TEST_OWNER_PASSWORD"].map { (email, $0) }
        }
        self.testHooks = testHooks
    }

    /// `testHooks` boots the server with `MARFA_TEST_HOOKS`, so ``advanceClock(by:)`` can move its clock.
    static func boot(testHooks: Bool = false) async throws -> OwnServer {
        let state = FileManager.default.temporaryDirectory.appending(path: "marfa-own-server-\(UUID())")
        let exports = try await up(state, testHooks: testHooks)
        return try OwnServer(state: state, exports: exports, testHooks: testHooks)
    }

    /// Moves the server's clock on, through the test hook on its control socket.
    func advanceClock(by duration: Duration) async throws {
        let socket = try #require(socket, "the server printed no control socket")
        let body = "{\"advance_ms\":\(Int64(duration.components.seconds) * 1000)}"
        let printed = try await Self.run(
            "/usr/bin/curl",
            [
                "--silent", "--show-error", "--fail", "--unix-socket", socket, "-X", "POST", "-H",
                "Content-Type: application/json", "--data", body, "http://localhost/_control/test/clock",
            ], environment: [:])
        try #require(printed.contains("offset_ms"), "the clock hook answered \(printed)")
    }

    /// Retires every event but the newest, as the server's retention does once the rest are older than it keeps.
    func pruneEventLog() async throws {
        _ = try await Self.run(
            "/usr/bin/sqlite3",
            [
                state.appending(path: "marfa.db").path,
                "PRAGMA busy_timeout = 5000; DELETE FROM event_log WHERE id < (SELECT MAX(id) FROM event_log);",
            ], environment: [:])
    }

    func stop() async throws {
        _ = try await Self.script("server-down.sh", [env.path], keep: state)
    }

    func start() async throws {
        let exports = try await Self.up(state, testHooks: testHooks)
        try #require(exports["MARFA_TEST_URL"] == url.absoluteString, "the server came back at another address")
    }

    /// Stops it and takes its state away.
    func end() async throws {
        try await stop()
        try? FileManager.default.removeItem(at: state)
    }

    private static func up(_ state: URL, testHooks: Bool) async throws -> [String: String] {
        let printed = try await script("server-up.sh", [], keep: state, testHooks: testHooks)
        var exports: [String: String] = [:]
        for line in printed.split(separator: "\n") where line.hasPrefix("export ") {
            let pair = line.dropFirst("export ".count).split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            exports[String(pair[0])] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        }
        return exports
    }

    private static func script(_ name: String, _ arguments: [String], keep: URL, testHooks: Bool = false)
        async throws -> String
    {
        let monorepo = try #require(monorepo, "MARFA_MONOREPO names no checkout")
        var environment = ProcessInfo.processInfo.environment
        environment["MARFA_SERVER_KEEP"] = keep.path
        environment["MARFA_SERVER_ENV"] = keep.appending(path: "env").path
        environment.removeValue(forKey: "PORT")
        if testHooks { environment["MARFA_TEST_HOOKS"] = "true" }
        return try await run(
            "/bin/bash", [monorepo.appending(path: "core/scripts/\(name)").path] + arguments,
            environment: environment)
    }

    private static func run(_ executable: String, _ arguments: [String], environment: [String: String])
        async throws -> String
    {
        let name = URL(filePath: executable).lastPathComponent
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment.isEmpty ? nil : environment
        let output = Pipe()
        process.standardOutput = output
        // A failed boot writes the server's log here, its secret redacted.
        process.standardError = FileHandle.standardError
        let ended = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        // Read off the concurrency pool: a boot can take a while.
        let printed = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: output.fileHandleForReading.readDataToEndOfFile())
            }
        }
        var status: Int32 = -1
        for await code in ended { status = code }
        try #require(status == 0, "\(name) exited \(status)")
        return String(decoding: printed, as: UTF8.self)
    }
}

/// A clock that moves only when a test advances it, so a wait the code under test asks for is seen and ended
/// by the test, not by the machine's speed.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Waiter {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextId = 0
        var waiters: [Waiter] = []
        var requested: [Duration] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// Every wait asked for, in order, as the length asked.
    var requested: [Duration] { state.withLock { $0.requested } }

    /// The waits not yet ended.
    var waiting: Int { state.withLock { $0.waiters.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state -> Int in
            state.nextId += 1
            state.requested.append(state.now.duration(to: deadline))
            return state.nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLock { state -> Result<Void, any Error>? in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0) }
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on and ends the waits it reaches.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Waiter] in
            state.now = state.now.advanced(by: duration)
            let due = state.waiters.filter { $0.deadline <= state.now }
            state.waiters.removeAll { $0.deadline <= state.now }
            return due
        }
        for waiter in due { waiter.continuation.resume() }
    }
}
