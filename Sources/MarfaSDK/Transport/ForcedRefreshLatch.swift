import Foundation

/// Stands the forced-renewal path down once it has failed to help.
///
/// A 401 on a clock-valid token is usually staleness: the credential was
/// revoked, rotated, or the clock drifted, and naming it to the provider
/// recovers the session. But a 401 that survives a credential the server has
/// never seen is not a staleness problem, and renewing again only adds
/// token-endpoint traffic to a request that is failing for some other reason.
/// Without this, ten requests against a server that refuses every token
/// produced ten token exchanges and twenty API calls.
///
/// One instance per transport, shared by every path that can force a renewal,
/// so the three paths cannot each keep their own idea of whether the mechanism
/// is standing. An actor because those paths run concurrently.
///
/// Mirrors `forcedRefreshSuppressed` in the TypeScript SDK's transport,
/// including the deliberately forgiving clear: any non-401 response releases
/// the latch, so interleaved healthy traffic can stop it engaging. That bounds
/// recovery attempts one-to-one with failures rather than exponentially, and
/// it needs a server that 401s a valid token — which the Marfa data plane does
/// not do, since permission failures are 403.
actor ForcedRefreshLatch {

    private var suppressed = false

    init() {}

    /// Whether a forced renewal may be attempted right now.
    var allowsForcedRefresh: Bool { !suppressed }

    /// Feed every response through this.
    ///
    /// - Parameters:
    ///   - statusCode: the status the server returned.
    ///   - afterForcedRefresh: whether this response came back on a credential
    ///     this transport had just renewed. A 401 there is what engages the
    ///     latch; a 401 on a first attempt is the ordinary case the mechanism
    ///     exists to fix.
    func record(statusCode: Int, afterForcedRefresh: Bool) {
        if statusCode != 401 {
            suppressed = false
        } else if afterForcedRefresh {
            suppressed = true
        }
    }
}
