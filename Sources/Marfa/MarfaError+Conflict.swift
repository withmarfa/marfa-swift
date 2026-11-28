extension MarfaError {
    /// The current `version` of a webhook whose change the server refused as stale.
    ///
    /// It is the `error.details.version` of the server's `version_conflict` answer to a webhook change, and `nil`
    /// for any other error and for a conflict whose answer names none. Read the webhook again to see what changed.
    public var currentVersion: Int? {
        conflictDetail("version")?.integer.flatMap { Int(exactly: $0) }
    }

    /// The current `revision` of a type whose replacement or deletion the server refused as stale.
    ///
    /// It is the `error.details.revision` of the server's `version_conflict` answer, and `nil` for any other error
    /// and for a conflict whose answer names none. Read the type again to see what changed.
    public var currentRevision: String? {
        conflictDetail("revision")?.string
    }

    private func conflictDetail(_ key: String) -> JSONValue? {
        guard case .versionConflict(_, let server) = self else { return nil }
        return server?.details?.object?[key]
    }
}
