/// Protocol satisfied by every generated domain-model struct.
///
/// Each concrete type (``CoreNote``, ``CoreTask``, ``CoreMediaArticle``, …)
/// wraps a generic ``Item`` from the Marfa API and exposes typed property
/// accessors generated from the Marfa type registry.
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
public protocol MarfaItem: Sendable {

    // MARK: Required

    /// The Marfa type identifier for this domain model.
    /// Examples: `"core.note"`, `"core.task"`, `"core.media.article"`.
    static var typeIdentifier: String { get }

    /// The underlying generic item from the Marfa API.
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

extension MarfaItem {

    // MARK: Identity

    /// The server-assigned item ID.
    public var id: String { item.id }

    /// The Marfa type string (same as ``typeIdentifier``).
    public var type: String { item.type }

    // MARK: Lifecycle

    /// Current lifecycle state.
    public var state: ItemState { item.state }

    /// `true` when the item is in the ``ItemState/active`` state.
    public var isActive: Bool { item.state == .active }

    /// `true` when the item is in the ``ItemState/trashed`` state.
    public var isTrashed: Bool { item.state == .trashed }

    /// `true` when the item is in the ``ItemState/archived`` state.
    public var isArchived: Bool { item.state == .archived }

    // MARK: Timestamps

    /// ISO 8601 creation timestamp.
    public var createdAt: String { item.createdAt }

    /// ISO 8601 last-update timestamp.
    public var updatedAt: String { item.updatedAt }

    /// ISO 8601 user-facing timestamp (may differ from `createdAt`).
    public var timestamp: String { item.timestamp }

    // MARK: Versioning

    /// Monotonically increasing server version counter.
    public var version: Int { item.version }

    /// Schema version at the time the item was last written.
    public var schemaVersion: Int { item.schemaVersion }

    // MARK: Provenance

    /// The source client that created this item.
    public var source: String { item.source }

    /// The client-assigned idempotency key (UUIDv7).
    public var sourceId: String? { item.sourceId }

    /// The item's tier: `library` for curated content, `feed` for
    /// high-volume capture, or `nil` for `system.*` items that have no
    /// tier dimension.
    public var tier: Tier? { item.tier }
}
