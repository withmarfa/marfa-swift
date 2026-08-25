import Foundation
import SwiftData

// MARK: - Predicate safety
//
// See `Sources/MarfaSDK/LocalStore/Schema/PredicateConventions.swift`.
// The descriptor narrows on stored columns only (`type`, `stateRaw`,
// `tierRaw`) via the captured-value short-circuit pattern (rule 8), and
// compares state against the persisted rawValue (rule 7). Text matching
// deliberately happens in Swift rather than in the predicate: `title`
// and `body` live inside the `propertiesData` JSON blob, which the
// predicate engine cannot see (rule 4).

extension LocalStore {

    /// Result cap applied when the caller doesn't set one, matching the
    /// server's `GET /search` default so an unbounded query returns the
    /// same number of rows on either side. Pass an explicit
    /// ``SearchFilters/limit`` to widen it.
    static let defaultSearchLimit = 20

    /// Full-text-ish search over item `title` and `body`, served entirely
    /// from the local store — no network, works offline.
    ///
    /// ## What this is, and what it is not
    ///
    /// The server backs `GET /search` with SQLite FTS5: a real inverted
    /// index, BM25 ranking, and `<mark>` snippets. SwiftData exposes no
    /// FTS index, and a predicate cannot reach inside a JSON column, so
    /// this implementation narrows on the indexed columns it *can*
    /// (`type`, `state`, `tier`) and then **scans the surviving rows in
    /// Swift**, decoding each one's `properties` blob to read its text.
    ///
    /// ## Cost
    ///
    /// Cost is linear in the rows that survive the column filters, with
    /// one JSON decode per row. Measured on an Apple Silicon laptop
    /// against an on-disk store with every row matching, it lands around
    /// **100 ms at 1,000 items, 800 ms at 10,000, and several seconds at
    /// 50,000**. Those anchors move with row size, hardware and load —
    /// the number worth carrying is the rate: *tens of milliseconds per
    /// thousand items*, not a few milliseconds total. Narrowing with
    /// `type` or `tier` is the cheapest lever a caller has, because it
    /// removes rows before the decode.
    ///
    /// **`limit` does not bound the work, only the answer.** Every row
    /// that matches is decoded, scored, joined to its metadata and
    /// sorted; the cap is applied last. A query matching 60,000 items
    /// takes seconds whether the caller asks for 20 results or all of
    /// them. Bounding the working set is not a free change — the `tags`
    /// filter runs after the metadata join, so candidates cannot be
    /// dropped before it without risking an under-filled result — so it
    /// is deliberately not attempted here.
    ///
    /// Being on the store actor also means a scan holds it for its
    /// duration, so writes queued behind it wait. That is true of every
    /// read here; search is only notable because it is the longest one.
    /// It is the reason a corpus that outgrows this needs the server
    /// index rather than a bigger machine.
    ///
    /// The scan checks for cancellation as it goes, so an abandoned
    /// query — the common case in search-as-you-type — stops paying for
    /// itself rather than holding the actor to completion and making the
    /// next term wait behind it.
    ///
    /// ## Known divergences from `MarfaClient.search(query:filters:)`
    ///
    /// The server's index covers **every textual property plus tags**.
    /// This one reads two literal keys, `title` and `body`, and that gap
    /// is wider than it sounds:
    ///
    /// - **Fields.** Types whose text lives under other keys never match
    ///   at all — `core.entity` and its subtypes (`name`), `core.highlight`
    ///   and `readwise.highlight` (`text`, `note`). A
    ///   `marfa.captured_email` matches on `body` but never on its
    ///   `subject`. This is a whole-type blind spot, not a partial one.
    /// - **Tags.** The server indexes tags as searchable text, so an item
    ///   tagged `fiction` is a hit for the query `fiction`. Locally it is
    ///   not. `SearchFilters.tags` still *filters* identically; tags are
    ///   simply not *matched*.
    /// - **`type` does not resolve subtypes.** The server matches by
    ///   inheritance, so `type: "core.media"` returns `core.media.book`.
    ///   Locally the comparison is literal, so it does not. Resolving
    ///   inheritance needs the type graph, which the local store does not
    ///   persist; approximating it from the dotted name would be wrong
    ///   for exactly the types a consumer app defines, since a custom
    ///   type may name any parent.
    /// - **`limit` range.** The server declares `1...100` and rejects
    ///   anything outside it. Locally `0` and negatives return an empty
    ///   result, and a value above 100 is honored rather than clamped.
    /// - **Ranking.** Scores are ordinal — derived from *where* the match
    ///   landed, not from term statistics. They order results sensibly
    ///   but are not BM25 and are not comparable to a server score.
    /// - **Snippets.** ``SearchResult/snippetHtml`` is always `nil`;
    ///   there is no local highlighter.
    /// - **`SearchFilters.filter`.** The server's structured filter
    ///   expression is not evaluated locally and is ignored, matching how
    ///   ``LocalStore/makeItemsDescriptor(filters:)`` treats
    ///   `ListFilters.filter`.
    ///
    /// What does match the server: `state`, `tier` and `tags` filter
    /// identically; `system.*` records stay out of the results unless the
    /// caller names a `system.` type outright; `trashed` items stay out
    /// unless `state` asks for them; and `limit` defaults to the server's
    /// 20. Everything else above is a difference a caller swapping
    /// between local and remote has to plan for.
    ///
    /// - Parameters:
    ///   - text: The query. Matching is case- and diacritic-insensitive,
    ///     and the text is trimmed first — blank input returns `[]`
    ///     rather than every row.
    ///   - filters: Same surface as the remote call.
    /// - Returns: Results ordered relevance DESC, then `updatedAt` DESC,
    ///   then `id` ASC, so equal-scoring rows keep a stable order across
    ///   repeated calls.
    func searchItems(text: String, filters: SearchFilters? = nil) throws -> [SearchResult] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        // Checked here rather than after the work. A non-positive limit means
        // an empty answer whatever the store holds, and the guard used to sit
        // past the fetch, the decode, the metadata join and the sort — so
        // `limit: 0` held the actor for seconds over a large store to return
        // nothing.
        let requestedLimit = filters?.limit ?? Self.defaultSearchLimit
        guard requestedLimit > 0 else { return [] }

        try Task.checkCancellation()
        let models = try modelContext.fetch(Self.makeSearchDescriptor(filters: filters))

        // Rank before touching metadata so the second read only covers
        // rows that actually matched the text.
        //
        // The per-row cancellation check is what keeps an abandoned
        // search cheap. This method is synchronous and holds the store
        // actor for its whole run, so without it a caller that cancelled
        // — search-as-you-type moving to the next keystroke — would still
        // wait out the full scan before its replacement could start, and
        // every term in a burst would serialize behind the one before it.
        var scored: [(model: MarfaItemModel, score: Double)] = []
        for model in models {
            try Task.checkCancellation()
            let properties = model.properties
            guard let score = Self.relevance(
                title: properties["title"]?.stringValue,
                body: properties["body"]?.stringValue,
                needle: needle
            ) else { continue }
            scored.append((model, score))
        }
        guard !scored.isEmpty else { return [] }

        let ids = Set(scored.map(\.model.id))
        let metaPredicate = #Predicate<MarfaMetadataModel> { ids.contains($0.itemId) }
        let metaModels = try modelContext.fetch(
            FetchDescriptor<MarfaMetadataModel>(predicate: metaPredicate)
        )
        // `uniqueKeysWithValues` traps on a duplicate key, and a duplicate is
        // constructible here: `MarfaMetadataModel` carries an index on
        // `itemId` but deliberately no `#Unique`, because CloudKit mirroring
        // forbids one, and writes are serialised only within a single
        // `LocalStore`. Two devices setting metadata on the same item can
        // therefore leave two rows, and this sits on the search path — so the
        // crash would land on every keystroke. Last write wins, which matches
        // what a later fetch would have returned anyway.
        // Resolved to the FIRST row, not the newest, because `fetchMetadata`
        // and `writeMetadata` both take `.first` under a `fetchLimit` of 1.
        // Picking differently here would not crash — it would render one row
        // in a list and a different one in the detail view of the same item,
        // permanently, since nothing deduplicates. Fetch order is also not
        // recency: no descriptor here sorts, so "newest" would be a guess.
        let metadataById = Dictionary(
            metaModels.map { ($0.itemId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // `tags` is an AND filter on the server — an item must carry every
        // requested tag — and tags live in the opaque `tagsData` blob, so
        // the check happens here rather than in the predicate.
        let requiredTags = Set(filters?.tags ?? [])

        var results: [SearchResult] = []
        results.reserveCapacity(scored.count)
        for entry in scored {
            let metadata = metadataById[entry.model.id]?.toWireMetadata()
                ?? Metadata(extensions: [:], itemId: entry.model.id, tags: [])
            if !requiredTags.isEmpty, !requiredTags.isSubset(of: Set(metadata.tags)) {
                continue
            }
            results.append(
                SearchResult(
                    item: entry.model.toWireItem(),
                    metadata: metadata,
                    relevanceScore: entry.score,
                    snippetHtml: nil
                )
            )
        }

        results.sort { lhs, rhs in
            if lhs.relevanceScore != rhs.relevanceScore {
                return lhs.relevanceScore > rhs.relevanceScore
            }
            if lhs.item.updatedAt != rhs.item.updatedAt {
                return lhs.item.updatedAt > rhs.item.updatedAt
            }
            return lhs.item.id < rhs.item.id
        }

        return results.count > requestedLimit
            ? Array(results.prefix(requestedLimit))
            : results
    }

    // MARK: - Descriptor

    /// Column-level narrowing for a search, shared by the actor method
    /// and exercised directly by the predicate-safety tests.
    ///
    /// Deliberately carries no `fetchLimit`: ``SearchFilters/limit`` caps
    /// *results*, and capping the fetch instead would silently drop rows
    /// before they were ever ranked.
    nonisolated static func makeSearchDescriptor(
        filters: SearchFilters?
    ) -> FetchDescriptor<MarfaItemModel> {
        let typeFilter = filters?.type ?? ""
        let hasTypeFilter = filters?.type != nil
        let stateFilter = filters?.state?.rawValue ?? ""
        let hasStateFilter = filters?.state != nil
        let tierFilter = filters?.tier?.rawValue ?? ""
        let hasTierFilter = filters?.tier != nil
        let trashedRaw = ItemState.trashed.rawValue

        // `system.*` records are operational, not user data, and the
        // server drops them from search unless the caller asks for a
        // system type by name. Mirror that rather than leaking device
        // and connection rows into an app's search field.
        let systemPrefix = "system."
        let excludeSystemTypes = !(filters?.type?.hasPrefix(systemPrefix) ?? false)

        let predicate = #Predicate<MarfaItemModel> { item in
            (!hasTypeFilter || item.type == typeFilter) &&
            ((hasStateFilter && item.stateRaw == stateFilter) ||
             (!hasStateFilter && item.stateRaw != trashedRaw)) &&
            (!hasTierFilter || item.tierRaw == tierFilter) &&
            (!excludeSystemTypes || !item.type.starts(with: systemPrefix))
        }

        return FetchDescriptor<MarfaItemModel>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
    }

    // MARK: - Ranking

    /// Ordinal relevance for one candidate. `nil` means "no match".
    ///
    /// The weights encode a single rule: a hit in the title beats a hit
    /// in the body, and a tighter hit beats a looser one (whole field,
    /// then prefix, then substring). The absolute values mean nothing
    /// beyond that ordering — they exist so ``SearchResult/relevanceScore``
    /// carries something sortable instead of a constant.
    nonisolated static func relevance(
        title: String?,
        body: String?,
        needle: String
    ) -> Double? {
        let best = max(
            fieldScore(title, needle: needle, whole: 1.0, prefix: 0.9, substring: 0.75),
            fieldScore(body, needle: needle, whole: 0.6, prefix: 0.55, substring: 0.5)
        )
        return best > 0 ? best : nil
    }

    private nonisolated static func fieldScore(
        _ field: String?,
        needle: String,
        whole: Double,
        prefix: Double,
        substring: Double
    ) -> Double {
        guard let field, !field.isEmpty else { return 0 }
        // Diacritic-insensitive so "cafe" finds "Café" — the behavior a
        // person typing into a search field expects, and close to what
        // the server's FTS tokenizer does.
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if field.compare(needle, options: options) == .orderedSame { return whole }
        guard let range = field.range(of: needle, options: options) else { return 0 }
        return range.lowerBound == field.startIndex ? prefix : substring
    }
}
