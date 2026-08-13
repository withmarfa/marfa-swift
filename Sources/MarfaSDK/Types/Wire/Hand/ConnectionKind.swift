/// Discriminator for `system.connection` items — identifies which kind of
/// external authority a connection represents.
///
/// - ``app``: an OAuth client this user has authorized to act on their behalf
///   (e.g. Notes signing in via Auth Code + PKCE). Carries `client_id`,
///   `scopes`, and lifecycle bookkeeping.
/// - ``integration``: a hosted or local integration the user has installed to
///   read or write Marfa items on their behalf (e.g. a calendar sync).
///   Carries `integration_ref`, `credential_ref`, and runtime status.
///
/// The OpenAPI spec carries `kind` as a plain string in connection items; the
/// SDK imposes this closed set so callers can pattern-match without comparing
/// raw strings. Decoding a wire payload that carries an unknown value fails
/// loudly.
public enum ConnectionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case app
    case integration
}

/// Lifecycle status of a connection, universal across every kind.
///
/// The `system.*` namespace uses a bounded two-state lifecycle rather than
/// the three-state one ordinary items carry: a connection is either live or
/// it has been revoked, and there is no archived middle.
///
/// Not to be confused with an integration's operational health, which is a
/// separate axis and a wider set of values.
public enum ConnectionStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case active
    case revoked
}
