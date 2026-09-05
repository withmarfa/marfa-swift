import Foundation

/// Which axis of a store's identity disagreed with the client opening it.
public enum StoreIdentityAxis: String, Sendable, Equatable {
    /// The server the store's contents came from.
    case origin
}

/// A store opened by a client it does not belong to.
///
/// **This refuses rather than reconciling, and there is nothing to reconcile.**
/// A store holds one server's rows, one event cursor and a queue of writes
/// addressed to that server. Opening it against a different origin does not
/// produce a store with two servers' data in it — it produces one where every
/// later answer overwrites rows that were never the same rows, and a queue
/// that replays somebody's edits at a server that has never heard of them.
/// The failure is silent and there is no later signal that distinguishes it
/// from ordinary drift.
public final class StoreIdentityMismatchError: MarfaError {
    /// Which axis disagreed. Named rather than described, because the
    /// remedies differ and a caller has to tell them apart.
    public let axis: StoreIdentityAxis

    /// What the store recorded.
    public let recorded: String

    /// What the client opening it carries.
    public let found: String

    public init(axis: StoreIdentityAxis, recorded: String, found: String) {
        self.axis = axis
        self.recorded = recorded
        self.found = found
        super.init(
            code: "store_identity_mismatch",
            message: """
                This store belongs to a different \(axis.rawValue): it recorded \
                \(recorded) and this client carries \(found). Opening it anyway \
                would overwrite rows that are not the same rows and replay \
                queued writes at a server that has never seen them. Use a \
                separate store path per \(axis.rawValue).
                """,
            status: 0
        )
    }

    /// Permanent by construction: nothing about a later attempt differs.
    public override var isPermanent: Bool { true }
}

// MARK: - Where it is recorded

/// The origin a store belongs to, kept beside it rather than inside it.
///
/// **It has to be readable before the database is opened**, and that decides
/// where it lives. Opening runs the migration plan and, for a store this build
/// cannot read, the fail-safe that moves it into quarantine — so a check that
/// waits for the store to be open has already let a client with no business
/// touching it migrate the thing, and possibly move it aside. There is nothing
/// to undo afterwards.
///
/// The cost of a sidecar is that it can be separated from the store: a copy
/// that takes the database and not this file looks unclaimed and will be
/// claimed by whoever opens it next. That is a fail-open and it is the same
/// behaviour as before this existed, which is the right direction for a file
/// somebody may not know to carry.
enum StoreOriginFile {

    /// Where it lives for a given store path. `nil` for an in-memory store,
    /// which has no file and belongs to nobody.
    static func path(for storePath: String) -> String? {
        storePath == ":memory:" ? nil : storePath + ".origin"
    }

    /// Compares the recorded origin, and records it when `claiming`.
    ///
    /// **Every client compares; only a writer records.** Gating both on the
    /// lock left a reader serving one server's rows through a client
    /// configured for another, which is the same failure on the read side. A
    /// reader over an unclaimed store leaves it unclaimed, because stamping an
    /// origin the writer never chose is exactly what the gate was for.
    static func check(storePath: String, origin: String, claiming: Bool) throws {
        guard let path = path(for: storePath) else { return }

        if let data = FileManager.default.contents(atPath: path),
           let recorded = String(data: data, encoding: .utf8), !recorded.isEmpty {
            guard recorded == origin else {
                throw StoreIdentityMismatchError(
                    axis: .origin, recorded: recorded, found: origin
                )
            }
            return
        }

        guard claiming else { return }
        let directory = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
        }
        try Data(origin.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// What the store records, or `nil` if it has never been claimed.
    static func recorded(storePath: String) -> String? {
        guard let path = path(for: storePath),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }
}
