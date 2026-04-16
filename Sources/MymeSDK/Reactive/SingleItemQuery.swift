import Foundation
import GRDB

// MARK: - SingleItemQuery

/// A live, observable query over a single item by ID.
///
/// The observation fires whenever the item row changes. If the item is purged,
/// ``item`` becomes `nil`.
///
/// ## Usage
///
///     let query = store.queryItem(id: item.id)
///     // In SwiftUI:
///     if let item = query.item { DetailView(item: item) }
@Observable
@MainActor
public final class SingleItemQuery {

    // MARK: - Published state

    /// The item, or `nil` if it has been purged or does not exist.
    public private(set) var item: Item?

    /// `true` while the initial fetch is in flight.
    public private(set) var isLoading: Bool = true

    /// Most recent observation error.
    public private(set) var error: Error?

    // MARK: - Internals

    private var cancellable: AnyDatabaseCancellable?

    // MARK: - Init

    init(pool: DatabasePool, id: String) {
        let observation = ValueObservation.tracking { db -> ItemRecord? in
            try ItemRecord
                .filter(Column("id") == id)
                .fetchOne(db)
        }

        cancellable = observation.start(
            in: pool,
            scheduling: .mainQueue,
            onError: { [weak self] error in
                self?.error = error
                self?.isLoading = false
            },
            onChange: { [weak self] record in
                self?.item = try? record?.toItem()
                self?.isLoading = false
                self?.error = nil
            }
        )
    }

    // MARK: - Lifecycle

    /// Stops the observation.
    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    deinit {
        cancellable?.cancel()
    }
}
