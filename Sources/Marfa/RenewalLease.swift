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
/// wall clock or a restart never makes a lease read as held longer than it is.
///
/// Every change to the lease item names the label it expects, so moving the lapse on or deleting the item is a
/// compare-and-swap: a holder whose lease lapsed and was taken finds another label and changes nothing.
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
    private let clock: @Sendable () -> UInt64
    private let gate: DispatchSemaphore
    private let state: Mutex<State>

    private init(place: SignInPlace, transport: SignInTransport, label: String, gate: DispatchSemaphore) {
        self.place = place
        lifetime = transport.leaseLifetime
        clock = transport.leaseClock
        self.gate = gate
        state = Mutex(State(label: label))
        let beat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let every = DispatchTimeInterval.nanoseconds(Int(Self.nanoseconds(lifetime) / 3))
        beat.schedule(deadline: .now() + every, repeating: every)
        beat.setEventHandler { [weak self] in self?.heartbeat() }
        state.withLock { $0.beat = beat }
        beat.resume()
    }

    /// Takes the place's lease, waiting while another holder has it, for up to two lifetimes.
    ///
    /// Blocks the calling thread while it waits; never call it on the main thread.
    static func take(_ place: SignInPlace, _ transport: SignInTransport) throws -> RenewalLease {
        let lifetime = transport.leaseLifetime
        // How long this caller waits is its own matter, not the lease's, so it is measured on Dispatch's clock.
        let giveUp = DispatchTime.now() + (lifetime * 2).seconds
        let gate = gate(for: place)
        guard gate.wait(timeout: giveUp) == .success else { throw Held() }
        do {
            while true {
                let mine = label(lapsingAt: transport.leaseClock() + nanoseconds(lifetime))
                if try place.keychain.add(label: mine, service: place.service, account: place.leaseAccount) {
                    return RenewalLease(place: place, transport: transport, label: mine, gate: gate)
                }
                guard let held = try place.keychain.label(service: place.service, account: place.leaseAccount)
                else { continue }
                if lapsed(held, lifetime: lifetime, now: transport.leaseClock()) {
                    try place.keychain.delete(label: held, service: place.service, account: place.leaseAccount)
                    continue
                }
                if DispatchTime.now() >= giveUp { throw Held() }
                Thread.sleep(forTimeInterval: transport.leasePoll.seconds)
            }
        } catch {
            gate.signal()
            throw error
        }
    }

    /// Moves the lapse on a full lifetime and runs `work`, only while the keychain still shows this holder's
    /// lease; answers `nil` otherwise.
    ///
    /// A lease that lapsed but that no other holder took is still this holder's, so the work runs. Another
    /// holder cannot take it while `work` runs, since a full lifetime is left and the heartbeat waits.
    ///
    /// Throws, writing nothing, when the keychain fails to move the lapse on: that proves nothing about who
    /// holds the lease, so this holder is not marked as having lost it.
    func whileHeld<T>(_ work: () throws -> T) throws -> T? {
        try state.withLock { state in
            guard !state.released, !state.lost else { return nil }
            guard try moveLapseOn(&state) else { return nil }
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

    private func heartbeat() {
        state.withLock { state in
            guard !state.released, !state.lost else { return }
            // A keychain that failed for a moment proves nothing about who holds the lease; the next beat tries
            // again, and the lapse in the label still bounds how long another holder waits.
            _ = try? moveLapseOn(&state)
        }
    }

    /// Relabels the lease item with a lapse a full lifetime away, only while it carries this holder's label.
    ///
    /// Answers whether it did. Where the item is gone or carries another label, this holder has lost the lease.
    private func moveLapseOn(_ state: inout State) throws -> Bool {
        let moved = Self.label(lapsingAt: clock() + Self.nanoseconds(lifetime))
        if try place.keychain.relabel(
            from: state.label, to: moved, service: place.service, account: place.leaseAccount)
        {
            state.label = moved
            return true
        }
        state.lost = true
        state.beat?.cancel()
        state.beat = nil
        return false
    }

    /// The clock leases lapse on, in nanoseconds, unless a transport names another.
    ///
    /// `CLOCK_UPTIME_RAW` is `mach_absolute_time()`, the clock Dispatch runs the heartbeat on. It is the same
    /// in every process, stops while the device sleeps and starts again at boot.
    static func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// This boot's identifier, so a lease written before a restart, on a clock that has since started again,
    /// reads as lapsed.
    static let bootSession: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }()

    /// `<holder> <boot session> <lapses at>`, the last on the lease's clock.
    static func label(lapsingAt lapse: UInt64) -> String {
        "\(UUID().uuidString) \(bootSession) \(lapse)"
    }

    /// Whether the lease `label` names has lapsed at `now` on the lease's clock.
    ///
    /// A lapse more than one `lifetime` ahead was never written on this boot's clock, since every holder writes
    /// now plus one lifetime: it is left from before a restart, where the boot's identifier could not be read.
    static func lapsed(_ label: String, lifetime: Duration, now: UInt64) -> Bool {
        let parts = label.split(separator: " ")
        guard parts.count == 3, parts[1] == bootSession, let lapses = UInt64(parts[2]) else { return true }
        return lapses <= now || lapses > now + nanoseconds(lifetime)
    }

    static func nanoseconds(_ duration: Duration) -> UInt64 {
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
