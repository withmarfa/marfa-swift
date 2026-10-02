import MarfaCoreNames
import Synchronization

/// The one place a working copy and all its parts reach the core, so the copy
/// can let it go and, for a new key, replace it.
///
/// A call holds a lease on the core while it runs. Closing or replacing waits
/// for the leases, then drops the core, and a core's store is released when it
/// is dropped. Closing reports done only once the drop is over, whichever
/// caller dropped it.
final class CoreHolder: Sendable {
    private enum Phase {
        case open
        case replacing
        /// One caller has been chosen to drop the core, and has not finished.
        case dropping
        case released
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

    var isClosed: Bool { state.withLock { $0.phase == .released } }

    /// Throws what `replace(key:)` would throw before it starts: `closed`, or
    /// `noServer` where there is no key to change.
    func checkKeyCanChange() throws {
        try state.withLock { state in
            if state.closing || state.phase == .dropping || state.phase == .released {
                throw MarfaError.closed(message: Self.closedMessage)
            }
            if reopen == nil { throw Self.noKey }
        }
    }

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
    /// core is dropped, so it can take as long as the slowest running call.
    ///
    /// Every caller returns only after the drop, whichever of them did it.
    func close() async {
        let elected = state.withLock { state in
            state.closing = true
            return elect(&state)
        }
        if elected {
            await releaseOffThread()
            return
        }
        await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Bool in
                guard state.phase != .released else { return true }
                state.closers.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Waits for the running calls, closes the old core, then opens the store
    /// again with `key` and holds that.
    ///
    /// From the start until the new core is held, every call throws
    /// `invalid`. When the store cannot be opened again the holder is closed,
    /// and a `close()` that arrived meanwhile closes it: this throws `closed`.
    func replace(key: String) async throws {
        try state.withLock { state in
            switch state.phase {
            case .dropping, .released: throw MarfaError.closed(message: Self.closedMessage)
            case .replacing: throw MarfaError.invalid(message: Self.replacingMessage)
            case .open:
                if state.closing { throw MarfaError.closed(message: Self.closedMessage) }
                if reopen == nil { throw Self.noKey }
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
        let (elected, closedMeanwhile) = state.withLock { state -> (Bool, Bool) in
            if case .success(let core) = reopened {
                state.core = core
                if !state.closing {
                    state.handle = Handle(core.heldHandle())
                    state.phase = .open
                    return (false, false)
                }
            }
            state.phase = .dropping
            return (true, state.closing)
        }
        if elected { await releaseOffThread() }
        if closedMeanwhile { throw MarfaError.closed(message: Self.closedMessage) }
        if case .failure(let error) = reopened { throw error }
    }

    static let closedMessage = "this working copy is closed"
    private static let noKey = MarfaError.noServer(
        message: "this working copy has no server, so it has no key to change")
    private static let replacingMessage = "this working copy is changing its key; ask again"

    private func lease() throws -> Core {
        try state.withLock { state in
            switch state.phase {
            case .dropping, .released: throw MarfaError.closed(message: Self.closedMessage)
            case .replacing:
                throw state.closing
                    ? MarfaError.closed(message: Self.closedMessage)
                    : MarfaError.invalid(message: Self.replacingMessage)
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
        let (elected, drained) = state.withLock { state -> (Bool, CheckedContinuation<Void, Never>?) in
            state.leases -= 1
            guard state.leases == 0 else { return (false, nil) }
            return (elect(&state), state.drained.take())
        }
        if elected { releaseNow() }
        drained?.resume()
    }

    /// Chooses the caller that drops the core: once a close was asked for,
    /// nothing leases the core and nobody has been chosen yet.
    private func elect(_ state: inout State) -> Bool {
        guard state.closing, state.phase == .open, state.leases == 0 else { return false }
        state.phase = .dropping
        return true
    }

    /// Releasing a store can block, so the cooperative pool is left free.
    private func releaseOffThread() async {
        _ = try? await background { [self] in releaseNow() }
    }

    /// Drops the core, and only then tells the closers waiting for the store.
    private func releaseNow() {
        var core = state.withLock { $0.core.take() }
        core = nil
        let closers = state.withLock { state in
            state.phase = .released
            return state.closers.drain()
        }
        for closer in closers { closer.resume() }
    }
}

extension Array {
    mutating func drain() -> [Element] {
        defer { self = [] }
        return self
    }
}
