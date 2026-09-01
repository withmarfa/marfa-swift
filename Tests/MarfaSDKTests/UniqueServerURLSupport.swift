import Foundation

/// Mints a bare server URL on a host no other test uses.
///
/// `OAuthDiscovery.shared` is a process-wide cache keyed by the canonical
/// issuer — path included, so two spaces served from one host occupy
/// separate entries — and the suite runs under `--parallel`, so suites
/// execute concurrently even when each one is individually `.serialized`.
/// Tests that shared a host therefore shared cache entries: one test's
/// cached endpoints satisfied another's first call, leaving that test's
/// scripted discovery response unconsumed and shifting every later
/// response in its queue. Calling the actor's `reset()` to compensate made
/// it worse, because `reset()` clears *every* entry rather than the
/// caller's own.
///
/// A host nobody else uses makes every issuer derived beneath it unique
/// too, which removes the sharing instead of sequencing access to it: an
/// entry no other test can reach always starts cold, so no reset is needed
/// and no test can perturb another. Prefer this over any process-wide
/// reset in new tests.
///
/// The result is a server URL, which is what the `serverURL:` entry points
/// take and derive an issuer from. `OAuthDiscovery`'s own unit tests pass
/// it straight in as an issuer identifier instead, which is equally valid:
/// that actor accepts whatever issuer a server publishes, and Marfa's
/// `/auth` layout is a fact about the platform rather than about discovery.
///
/// - Parameter label: Short, stable prefix identifying the calling test.
///   Appears in the host, so a stray request in a log is traceable to the
///   test that made it.
func uniqueServerURL(_ label: String) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "\(label)-\(HostCounter.next()).test"
    guard let url = components.url else {
        preconditionFailure("scheme + host should always compose: \(label)")
    }
    return url
}

/// Monotonic source of the disambiguating suffix. Tests run concurrently,
/// so the increment is lock-guarded.
private enum HostCounter {
    nonisolated(unsafe) private static var value = 0
    private static let lock = NSLock()

    static func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
