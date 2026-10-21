import Darwin
import Foundation
import Synchronization

/// One holder's turn to renew or write a sign-in, across this process and every process that shares the
/// keychain, such as an app and its extensions.
///
/// The keychain refuses a second item under one service and account, whichever process adds it, so whichever
/// adds the lease item first holds the lease. The item's label names when the lease lapses, so a lease left by a
/// process that died is taken over once it lapses. While it is held, the holder moves that moment on every third
/// of the lifetime, so a request that runs longer than the lifetime keeps it.
///
/// The moment is read on the clock the heartbeat runs on, which every process on the device shares, which stops
/// while the device sleeps and starts again at boot, with the boot's identifier beside it. A sleep stops the
/// lapse and the heartbeat together, so a holder never wakes to find its lease lapsed mid-request, and a changed
/// wall clock or a restart never makes a lease read as held longer than it is. A holder whose own lapse has
/// passed writes nothing.
final class RenewalLease: Sendable {
    struct Held: Error {}

    private struct State {
        /// The label the lease item carries, as far as this holder knows.
        var label: String
        /// Whether the lease item was found gone or relabeled when this holder moved the lapse on, so another
        /// holder may have taken it since.
        var lost = false
        var released = false
        var beat: (any DispatchSourceTimer)?
    }

    private let place: SignInPlace
    private let lifetime: Duration
    private let gate: DispatchSemaphore
    private let state: Mutex<State>

    private init(place: SignInPlace, lifetime: Duration, label: String, gate: DispatchSemaphore) {
        self.place = place
        self.lifetime = lifetime
        self.gate = gate
        state = Mutex(State(label: label))
        let beat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let every = DispatchTimeInterval.nanoseconds(Int(Self.nanoseconds(lifetime) / 3))
        beat.schedule(deadline: .now() + every, repeating: every)
        beat.setEventHandler { [weak self] in self?.moveLapseOn() }
        state.withLock { $0.beat = beat }
        beat.resume()
    }

    /// Takes the place's lease, waiting while another holder has it, for up to two lifetimes.
    ///
    /// Blocks the calling thread while it waits; never call it on the main thread.
    static func take(_ place: SignInPlace, _ transport: SignInTransport) throws -> RenewalLease {
        let lifetime = transport.leaseLifetime
        let giveUp = now() + nanoseconds(lifetime * 2)
        let gate = gate(for: place)
        guard gate.wait(timeout: .now() + (lifetime * 2).seconds) == .success else { throw Held() }
        do {
            while true {
                let mine = label(lapsingIn: lifetime)
                if try place.keychain.add(label: mine, service: place.service, account: place.leaseAccount) {
                    return RenewalLease(place: place, lifetime: lifetime, label: mine, gate: gate)
                }
                guard let held = try place.keychain.label(service: place.service, account: place.leaseAccount)
                else { continue }
                if lapsed(held, lifetime: lifetime) {
                    try place.keychain.delete(label: held, service: place.service, account: place.leaseAccount)
                    continue
                }
                if now() >= giveUp { throw Held() }
                Thread.sleep(forTimeInterval: transport.leasePoll.seconds)
            }
        } catch {
            gate.signal()
            throw error
        }
    }

    /// Runs `work` only while the keychain still shows this holder's lease with at least a third of its
    /// lifetime left, and answers `nil` otherwise.
    ///
    /// The lapse is not moved on while `work` runs, and a third of the lifetime is left, so no other holder can
    /// take the lease between the check and the write.
    func whileHeld<T>(_ work: () throws -> T) throws -> T? {
        try state.withLock { state in
            guard !state.released, !state.lost, !Self.lapsed(state.label, lifetime: lifetime, within: lifetime / 3),
                try place.keychain.label(service: place.service, account: place.leaseAccount) == state.label
            else { return nil }
            return try work()
        }
    }

    /// Lets the lease go, deleting only the item this holder put there.
    func release() {
        let label: String? = state.withLock { state in
            guard !state.released else { return nil }
            state.released = true
            state.beat?.cancel()
            state.beat = nil
            return state.label
        }
        guard let label else { return }
        try? place.keychain.delete(label: label, service: place.service, account: place.leaseAccount)
        gate.signal()
    }

    private func moveLapseOn() {
        state.withLock { state in
            guard !state.released, !state.lost else { return }
            let moved = Self.label(lapsingIn: lifetime)
            let kept: Bool
            do {
                kept = try place.keychain.relabel(
                    from: state.label, to: moved, service: place.service, account: place.leaseAccount)
            } catch {
                // A keychain that failed for a moment proves nothing about who holds the lease; the next beat
                // tries again, and the lapse in the label still bounds how long this holder may write.
                return
            }
            if kept {
                state.label = moved
            } else {
                state.lost = true
                state.beat?.cancel()
                state.beat = nil
            }
        }
    }

    /// The clock leases are read on, in nanoseconds.
    ///
    /// `CLOCK_UPTIME_RAW` is `mach_absolute_time()`, the clock Dispatch runs the heartbeat on. It is the same
    /// in every process, stops while the device sleeps and starts again at boot.
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// This boot's identifier, so a lease written before a restart, on a clock that has since started again,
    /// reads as lapsed.
    static let bootSession: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }()

    /// `<holder> <boot session> <lapses at>`, the last on ``now()``.
    static func label(lapsingIn lifetime: Duration) -> String {
        "\(UUID().uuidString) \(bootSession) \(now() + nanoseconds(lifetime))"
    }

    /// Whether the lease `label` names lapses within `margin` from now, or already has.
    ///
    /// A lapse more than one `lifetime` ahead was never written on this boot's clock, since every holder writes
    /// now plus one lifetime: it is left from before a restart, where the boot's identifier could not be read.
    static func lapsed(_ label: String, lifetime: Duration, within margin: Duration = .zero) -> Bool {
        let parts = label.split(separator: " ")
        guard parts.count == 3, parts[1] == bootSession, let lapses = UInt64(parts[2]) else { return true }
        let now = now()
        return lapses <= now + nanoseconds(margin) || lapses > now + nanoseconds(lifetime)
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
    }

    /// One gate a place's holders in this process wait on, so they queue here rather than polling the keychain.
    private static let gates = Mutex<[SignInPlace: DispatchSemaphore]>([:])

    private static func gate(for place: SignInPlace) -> DispatchSemaphore {
        gates.withLock { gates in
            if let gate = gates[place] { return gate }
            let gate = DispatchSemaphore(value: 1)
            gates[place] = gate
            return gate
        }
    }
}
