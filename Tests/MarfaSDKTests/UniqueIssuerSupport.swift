import Foundation

/// Mints an issuer origin that no other test uses.
///
/// `OAuthDiscovery.shared` is a process-wide cache keyed by issuer origin,
/// and the suite runs under `--parallel`, so suites execute concurrently
/// even when each one is individually `.serialized`. Tests that shared an
/// origin therefore shared cache entries: one test's cached endpoints
/// satisfied another's first call, leaving that test's scripted discovery
/// response unconsumed and shifting every later response in its queue.
/// Calling the actor's `reset()` to compensate made it worse, because
/// `reset()` clears *every* origin rather than the caller's own.
///
/// Minting an origin per test removes the sharing instead of sequencing
/// access to it: an origin nobody else uses always starts cold, so no
/// reset is needed and no test can perturb another. Prefer this over any
/// process-wide reset in new tests.
///
/// - Parameter label: Short, stable prefix identifying the calling test.
///   Appears in the host, so a stray request in a log is traceable to the
///   test that made it.
func uniqueIssuer(_ label: String) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "\(label)-\(IssuerCounter.next()).test"
    guard let url = components.url else {
        preconditionFailure("scheme + host should always compose: \(label)")
    }
    return url
}

/// Monotonic source of the disambiguating suffix. Tests run concurrently,
/// so the increment is lock-guarded.
private enum IssuerCounter {
    nonisolated(unsafe) private static var value = 0
    private static let lock = NSLock()

    static func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
