import Foundation
import Observation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// `stateRaw` is compared against a captured rawValue, never an enum case
// (rule 3). No other column is touched.

// MARK: - TypesInDataQuery

/// A live, observable query over the distinct item types present in the
/// local store.
///
/// Emits `[String]` sorted lexically. Re-runs whenever any item row
/// changes.
///
/// ## Why this exists rather than a count aggregate
///
/// "Which types does this space actually hold" has no cheap answer anywhere
/// else. No route returns it, no server aggregate exists, and it has to work
/// offline, so a walk over the item rows is the only way to know. What makes
/// the walk affordable is what it declines to do: it reads one column and
/// never calls `toWireItem()`, so no `propertiesData` blob is JSON-decoded.
/// That is the same trade ``TagsQuery`` makes, and the reason it is accepted
/// there applies here.
///
/// The alternative a consumer reaches for is an unfiltered
/// ``ItemsWithMetadataQuery`` and a walk over `item.type`, which materializes
/// and decodes the entire library on every store save to answer a question
/// about a filter menu. An app shipped exactly that.
///
/// ## Trashed rows and `system.*` types are excluded
///
/// A type whose only items are in the trash is not a type the space holds, and
/// a filter offering it matches nothing. ``TagsQuery`` already excludes trashed
/// rows, so a consumer building one filter list from both had the two
/// disagreeing: the type of a trashed item was offered while its tags were
/// not.
///
/// `system.*` types are left out on the same reasoning. `items.list()` does
/// not return those rows unless a caller names a system type outright, so a
/// chip for `system.activity` would filter a list that never shows them —
/// and they are operational records rather than anything a person filed. An
/// app that wants connections reads ``ConnectionsNamespace``.
///
/// ## Usage
///
///     let query = store.queryTypesInData()
///     ForEach(query.types, id: \.self) { typeId in
///         TypeChip(typeId)
///     }
@Observable
@MainActor
public final class TypesInDataQuery {

    // MARK: - Published state

    public private(set) var types: [String] = []
    public private(set) var isLoading: Bool = true
    public private(set) var error: Error?

    // MARK: - Internals

    private let context: ModelContext
    private var observer: RefetchObserver?

    // MARK: - Init

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        Task { @MainActor [weak self] in self?.refetch() }
        self.observer = RefetchObserver { [weak self] in self?.refetch() }
    }

    private func refetch() {
        do {
            let trashedRaw = ItemState.trashed.rawValue
            // `system.*` types are left out for the same reason trashed rows
            // are: this list is a filter menu, and a chip has to name
            // something an app's own list will show. `items.list()` excludes
            // system rows unless a caller names a system type outright, so
            // offering `system.activity` here would hand someone a filter for
            // rows the list beside it does not display — and these are
            // operational records rather than anything a person filed.
            //
            // Unconditional, unlike the listing's clause, because this query
            // takes no type filter: there is no caller asking for a system
            // type by name to make an exception for. An app that wants
            // connections reads `client.connections`, which is the typed API
            // for exactly that.
            let systemPrefix = "system."
            let predicate = #Predicate<MarfaItemModel> { item in
                item.stateRaw != trashedRaw &&
                !item.type.starts(with: systemPrefix)
            }
            let descriptor = FetchDescriptor<MarfaItemModel>(predicate: predicate)
            let models = try context.fetch(descriptor)
            var distinct: Set<String> = []
            for model in models {
                distinct.insert(model.type)
            }
            self.types = distinct.sorted()
            self.isLoading = false
            self.error = nil
        } catch {
            self.error = error
            self.isLoading = false
        }
    }

    // MARK: - Lifecycle

    public func stop() {
        observer?.cancel()
        observer = nil
    }
}
