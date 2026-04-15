/// Protocol satisfied by every generated domain-model struct.
///
/// Each concrete type (``CoreNote``, ``CoreTask``, ``CoreMediaArticle``, …)
/// wraps a generic ``Item`` from the Myme API and exposes typed property
/// accessors generated from the Myme type registry.
///
/// ## Usage
///
///     // Wrap a raw Item in a typed model:
///     if let note = CoreNote(from: item) {
///         print(note.title ?? "(untitled)")
///         print(note.body)
///     }
///
///     // Build properties for create/update:
///     var note = CoreNote(from: item)!
///     let props = note.toProperties()   // [String: JSONValue]
///     try await client.items.update(id: note.id, properties: props)
///
/// ## Implementing custom types
///
/// Application code can implement this protocol directly for types not yet
/// covered by the registry, or for proprietary namespaces.  The only contract
/// is that `init?(from:)` verifies `item.type == typeIdentifier` and that
/// all required fields are present.
public protocol MymeItem: Sendable {

    // MARK: Required

    /// The Myme type identifier for this domain model.
    /// Examples: `"core.note"`, `"core.task"`, `"core.media.article"`.
    static var typeIdentifier: String { get }

    /// The underlying generic item from the Myme API.
    var item: Item { get }

    /// Wraps a generic ``Item``.
    ///
    /// Returns `nil` if:
    /// - `item.type` does not match ``typeIdentifier``, or
    /// - a required property is absent from `item.properties`.
    init?(from item: Item)

    /// Serialises the typed properties back to a raw dictionary, suitable for
    /// ``CreateItemInput`` or
    /// ``ItemsNamespace/update(id:properties:options:)``.
    func toProperties() -> [String: JSONValue]
}

// MARK: - Default convenience accessors

public extension MymeItem {

    // MARK: Identity

    /// The server-assigned item ID.
    var id: String { item.id }

    /// The Myme type string (same as ``typeIdentifier``).
    var type: String { item.type }

    // MARK: Lifecycle

    /// Current lifecycle state.
    var state: ItemState { item.state }

    /// `true` when the item is in the ``ItemState/active`` state.
    var isActive: Bool { item.state == .active }

    /// `true` when the item is in the ``ItemState/trashed`` state.
    var isTrashed: Bool { item.state == .trashed }

    /// `true` when the item is in the ``ItemState/archived`` state.
    var isArchived: Bool { item.state == .archived }

    // MARK: Timestamps

    /// ISO 8601 creation timestamp.
    var createdAt: String { item.createdAt }

    /// ISO 8601 last-update timestamp.
    var updatedAt: String { item.updatedAt }

    /// ISO 8601 user-facing timestamp (may differ from `createdAt`).
    var timestamp: String { item.timestamp }

    // MARK: Versioning

    /// Monotonically increasing server version counter.
    var version: Int { item.version }

    /// Schema version at the time the item was last written.
    var schemaVersion: Int { item.schemaVersion }

    // MARK: Provenance

    /// The source client that created this item.
    var source: String { item.source }

    /// The client-assigned idempotency key (UUIDv7).
    var sourceId: String? { item.sourceId }

    /// How this item entered the user's library.
    var origin: Origin { item.origin }

    /// Whether this item is part of the user's library.
    var library: Bool { item.library }
}
