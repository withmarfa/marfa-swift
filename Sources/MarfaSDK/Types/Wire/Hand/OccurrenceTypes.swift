import Foundation

/// One dated instance of an event, produced by expanding a recurrence.
///
/// An occurrence is not a stored row: the server materializes it from a
/// series item's recurrence rule plus any exception items that override a
/// particular date. `item` is the item the occurrence came from, so a caller
/// that wants to edit it has an id to work with; `startsAt` and `endsAt` are
/// this occurrence's own instants rather than the series'.
public struct Occurrence: Codable, Sendable, Hashable {
    /// The instant this occurrence begins, in the shape the server stores.
    public let startsAt: String
    /// The instant it ends. Absent for an item that declares no end.
    public let endsAt: String?
    /// The item the occurrence was expanded from.
    public let item: Item
    /// The series this was expanded from, when it came from a recurrence
    /// rather than standing alone.
    public let seriesId: String?
    /// The date in the series this occurrence overrides, when it is an
    /// exception rather than a plain expansion.
    public let replaces: String?

    enum CodingKeys: String, CodingKey {
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case item
        case seriesId = "series_id"
        case replaces
    }
}

/// The window a set of occurrences was expanded over.
///
/// Always present, and worth reading rather than assuming: the server
/// bounds the expansion, so a caller that asked for a wider range than the
/// server will expand gets this narrower one back and no indication
/// anywhere else.
public struct OccurrenceWindow: Codable, Sendable, Hashable {
    public let from: String
    public let to: String
}

/// A series that could not be expanded, and why.
///
/// Reported rather than thrown: one unparseable recurrence rule should not
/// cost the caller every other occurrence in the window.
public struct OccurrenceSeriesError: Codable, Sendable, Hashable {
    public let itemId: String
    public let message: String

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case message
    }
}

/// What one `GET /occurrences` read cost, and how close it came to the
/// ceilings that would have truncated it.
///
/// Reported on every successful read rather than only on a refused one,
/// which is the point: a calendar approaching a limit is visible before a
/// request starts failing, instead of after.
public struct OccurrenceScan: Codable, Sendable, Hashable {
    /// Event rows read across every pass. Most of this cannot be narrowed by
    /// the window, so it grows with the calendar rather than with the range
    /// asked for.
    public let eventsRead: Int
    /// Occurrences returned — the length of `data`.
    public let occurrences: Int
    /// The ceiling `occurrences` is refused at.
    public let maxOccurrences: Int
    /// Failures found in recurrence rules, counted in entries rather than
    /// rows, so one bad row can account for two. A floor rather than a
    /// certificate: it counts the ways of being broken this route
    /// recognizes, across the event types this request actually read.
    public let seriesErrors: Int
    /// The longest ``OccurrencesResponse/seriesErrors`` list a response will
    /// carry. Past it the list is capped and the read still succeeds.
    public let maxSeriesErrors: Int
    /// Rule iterations spent on expansions that produced no occurrence.
    public let unproductiveIterations: Int
    /// The ceiling expansion stops at. Iterations on series that do produce
    /// occurrences are not counted against it, so a busy calendar cannot
    /// cross it on volume alone.
    public let maxUnproductiveIterations: Int
    /// Series left unexpanded because the ceiling was reached first. Zero on
    /// any read that finished.
    public let seriesUnexpanded: Int

    enum CodingKeys: String, CodingKey {
        case eventsRead = "events_read"
        case occurrences
        case maxOccurrences = "max_occurrences"
        case seriesErrors = "series_errors"
        case maxSeriesErrors = "max_series_errors"
        case unproductiveIterations = "unproductive_iterations"
        case maxUnproductiveIterations = "max_unproductive_iterations"
        case seriesUnexpanded = "series_unexpanded"
    }
}

/// Envelope for `GET /occurrences`.
public struct OccurrencesResponse: Codable, Sendable {
    public let data: [Occurrence]
    /// The range actually expanded, which may be narrower than the one asked
    /// for.
    public let window: OccurrenceWindow
    /// Series the server could not expand. Absent when every series in the
    /// window expanded cleanly.
    public let seriesErrors: [OccurrenceSeriesError]?
    /// What the read cost and how near the ceilings it came.
    public let scan: OccurrenceScan
    /// True when expansion stopped early, having spent its budget on series
    /// that yielded nothing. `data` may be missing occurrences the
    /// unexpanded series held, and `scan.seriesUnexpanded` counts them.
    /// Narrowing the window does not help — the budget is spent walking
    /// rules from their own start, before the window is reached.
    public let expansionIncomplete: Bool?
    /// True when ``seriesErrors`` lists fewer failures than the read found.
    /// `scan.seriesErrors` carries the real total.
    public let seriesErrorsTruncated: Bool?

    enum CodingKeys: String, CodingKey {
        case data, window, scan
        case seriesErrors = "series_errors"
        case expansionIncomplete = "expansion_incomplete"
        case seriesErrorsTruncated = "series_errors_truncated"
    }
}

/// How one field compares between an item and a mirror of it.
public enum ReconcileFieldState: String, Codable, Sendable {
    /// Both sides carry the same value.
    case same
    /// Both sides carry a value and they differ.
    case diverged
    /// Only the item has it.
    case onlyYours = "only_yours"
    /// Only the mirror has it.
    case onlyMirror = "only_mirror"
}

/// One field's comparison between an item and a mirror.
public struct ReconcileField: Codable, Sendable {
    public let key: String
    public let state: ReconcileFieldState
    /// The item's value. `nil` both when absent and when genuinely null —
    /// `state` is what distinguishes those.
    public let yours: JSONValue?
    /// The mirror's value, under the same caveat.
    public let mirror: JSONValue?
}

/// An upstream record that mirrors an item, with a field-by-field comparison.
public struct ReconcileMirror: Codable, Sendable {
    public let mirrorId: String
    public let mirrorType: String
    public let mirrorSource: String
    public let mirrorUpdatedAt: String
    public let fields: [ReconcileField]

    enum CodingKeys: String, CodingKey {
        case mirrorId = "mirror_id"
        case mirrorType = "mirror_type"
        case mirrorSource = "mirror_source"
        case mirrorUpdatedAt = "mirror_updated_at"
        case fields
    }
}

/// Envelope for `GET /items/{id}/reconcile`.
public struct ReconcileResponse: Codable, Sendable {
    public let mirrors: [ReconcileMirror]
}
