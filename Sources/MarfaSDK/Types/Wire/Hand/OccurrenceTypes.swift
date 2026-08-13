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

    enum CodingKeys: String, CodingKey {
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case item
    }
}

/// Envelope for `GET /occurrences`.
public struct OccurrencesResponse: Codable, Sendable {
    public let data: [Occurrence]
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
