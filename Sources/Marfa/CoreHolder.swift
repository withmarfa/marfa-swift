import MarfaCoreNames
import Synchronization

/// The one place a working copy and all its parts reach the core, so the copy
/// can let it go and, for a new key, replace it.
///
/// A call holds a lease on the core while it runs. Closing or replacing waits
/// for the leases, then drops the core before it reports done, and a core's
/// store is released when it is dropped.
final class CoreHolder: Sendable {
    private enum Phase {
        case open
        case replacing
        case closed
    }

    private struct State {
        var core: Core?
        var phase = Phase.open
        var closing = false
        var leases = 0
        var drained: CheckedContinuation<Void, Never>?
        var closers: [CheckedContinuation<Void, Never>] = []
        var handle: Handle
    }

    private let state: Mutex<State>
    private let reopen: (@Sendable (String) throws -> Core)?

    /// `reopen` makes the core again from a new key; `nil` where the copy has
    /// no server and so no key.
    init(_ core: Core, reopen: (@Sendable (String) throws -> Core)? = nil) {
        state = Mutex(State(core: core, handle: Handle(core.heldHandle())))
        self.reopen = reopen
    }

    /// What the copy held while it was open, and still the last thing it held
    /// once closed.
    var handle: Handle { state.withLock { $0.handle } }

    var isClosed: Bool { state.withLock { $0.phase == .closed } }

    /// Runs `work` off the caller's thread against the core.
    func run<T: Sendable>(_ work: @escaping @Sendable (Core) throws -> T) async throws -> T {
        try await background { [self] in try with(work) }
    }

    /// Runs `work` on this thread against the core, translating the core's errors.
    func with<T>(_ work: (Core) throws -> T) throws -> T {
        var core: Core? = try lease()
        let result = Result { try translated { try work(core.unsafelyUnwrapped) } }
        // The lease ends only once this reference is gone, so the store is
        // free the moment the last lease is.
        core = nil
        returnLease()
        return try result.get()
    }

    /// Refuses new calls and returns once the running ones are done and the
    /// core is dropped.
    ///
    /// A second call waits for the first.
    func close() async {
        var finished = state.withLock { state -> Finish? in
            state.closing = true
            return finish(&state)
        }
        guard case .some = finished else {
            await withCheckedContinuation { continuation in
                let done = state.withLock { state -> Bool in
                    guard state.phase != .closed else { return true }
                    state.closers.append(continuation)
                    return false
                }
                if done { continuation.resume() }
            }
            return
        }
        finished?.complete()
    }

    /// Closes the old core, then opens the store again with `key` and holds
    /// that.
    ///
    /// Calls that start meanwhile throw `invalid`. When the store cannot be
    /// opened again the holder is closed.
    func replace(key: String) async throws {
        try state.withLock { state in
            switch state.phase {
            case .closed: throw MarfaError.closed(message: Self.closedMessage)
            case .replacing: throw MarfaError.invalid(message: Self.replacingMessage)
            case .open:
                if state.closing { throw MarfaError.closed(message: Self.closedMessage) }
                if reopen == nil {
                    throw MarfaError.noServer(message: "this working copy has no server, so it has no key to change")
                }
                state.phase = .replacing
            }
        }
        guard let reopen else { return }
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                guard state.leases > 0 else { return true }
                state.drained = continuation
                return false
            }
            if ready { continuation.resume() }
        }
        _ = state.withLock { $0.core.take() }
        let reopened: Result<Core, any Error>
        do {
            reopened = .success(try await background { try reopen(key) })
        } catch {
            reopened = .failure(error)
        }
        var finished = state.withLock { state -> Finish in
            var dropped: Core?
            switch reopened {
            case .success(let core) where !state.closing:
                state.handle = Handle(core.heldHandle())
                state.core = core
                state.phase = .open
            case .success(let core):
                dropped = core
                state.phase = .closed
            case .failure:
                state.phase = .closed
            }
            let closers = state.phase == .closed ? state.closers.drain() : []
            return Finish(dropped: dropped, closers: closers)
        }
        finished.complete()
        _ = try reopened.get()
    }

    static let closedMessage = "this working copy is closed"
    private static let replacingMessage = "this working copy is changing its key; ask again"

    private func lease() throws -> Core {
        try state.withLock { state in
            switch state.phase {
            case .closed: throw MarfaError.closed(message: Self.closedMessage)
            case .replacing: throw MarfaError.invalid(message: Self.replacingMessage)
            case .open:
                guard !state.closing, let core = state.core else {
                    throw MarfaError.closed(message: Self.closedMessage)
                }
                state.leases += 1
                return core
            }
        }
    }

    private func returnLease() {
        var (finished, drained) = state.withLock { state -> (Finish?, CheckedContinuation<Void, Never>?) in
            state.leases -= 1
            guard state.leases == 0 else { return (nil, nil) }
            return (state.closing ? finish(&state) : nil, state.drained.take())
        }
        finished?.complete()
        drained?.resume()
    }

    private struct Finish {
        var dropped: Core?
        var closers: [CheckedContinuation<Void, Never>]

        mutating func complete() {
            dropped = nil
            for closer in closers { closer.resume() }
        }
    }

    /// Takes the core out once nothing leases it and a close was asked for.
    private func finish(_ state: inout State) -> Finish? {
        guard state.closing, state.phase == .open, state.leases == 0 else { return nil }
        state.phase = .closed
        return Finish(dropped: state.core.take(), closers: state.closers.drain())
    }
}

extension Array {
    fileprivate mutating func drain() -> [Element] {
        defer { self = [] }
        return self
    }
}
