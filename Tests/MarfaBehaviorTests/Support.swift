#if DEBUG
import Foundation
import Marfa
import MarfaTesting
import Synchronization
import Testing

func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "marfa-\(UUID()).sqlite")
}

func eventually(
    _ what: String, within seconds: Double = 5, isolation: isolated (any Actor)? = #isolation,
    _ condition: () async throws -> Bool
) async throws {
    let deadline = Date.now.addingTimeInterval(seconds)
    while try await !condition() {
        guard Date.now < deadline else {
            Issue.record("never: \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

final class Heard: Sendable {
    private final class Log: Sendable {
        let changes = Mutex<[Change]>([])
    }

    private let log: Log
    private let listening: Task<Void, Never>

    init(_ stream: AsyncStream<Change>) {
        let log = Log()
        self.log = log
        listening = Task {
            for await change in stream { log.changes.withLock { $0.append(change) } }
        }
    }

    deinit { listening.cancel() }

    var all: [Change] { log.changes.withLock { $0 } }

    var locals: [Change] {
        all.filter { if case .local = $0.origin { true } else { false } }
    }
}

/// The two copies the behavior suite holds to the same tests: the real one,
/// opened on a store in a temporary folder with no server, and the fake.
enum CopyKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case real
    case fake

    var testDescription: String {
        switch self {
        case .real: "real copy"
        case .fake: "fake copy"
        }
    }

    /// A copy that holds Marfa's built-in catalog and the types in `declaring`.
    func open(declaring: [JSONObject] = []) async throws -> WorkingCopy {
        let copy =
            switch self {
            case .real: try await WorkingCopy.open(store: temporaryStore())
            case .fake: try await Self.fake()
            }
        if !declaring.isEmpty { try await copy.declareTypes(declaring) }
        return copy
    }

    /// The fake is given the catalog a real copy holds before any hydration, so
    /// the two answer the same questions about the same types.
    private static func fake() async throws -> WorkingCopy {
        let (itemTypes, edgeTypes) = try await builtIn.value
        return WorkingCopy.fake(itemTypes: itemTypes, edgeTypes: edgeTypes).copy
    }

    private static let builtIn = Task {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let types = (try await copy.catalog.itemTypes(), try await copy.catalog.edgeTypes())
        await copy.close()
        return types
    }
}
#endif
