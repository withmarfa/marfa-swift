import Foundation
internal import MarfaCore

/// An item's type and properties to name and preview, with its ID when the copy may hold it.
public struct ItemDisplayInput: Sendable, Hashable {
    public var type: String
    public var properties: JSONObject
    /// The held item's ID, so a part with no title can be named after its host.
    public var id: String?

    public init(type: String, properties: JSONObject, id: String? = nil) {
        self.type = type
        self.properties = properties
        self.id = id
    }

    var core: MarfaCore.ItemDisplayInput { MarfaCore.ItemDisplayInput(type: type, properties: properties.core, id: id) }
}

/// The name and the preview text of an item, as the core works them out.
public struct ItemDisplay: Sendable, Hashable {
    /// The name the server gives the item, or `nil` where the server would say `Untitled`.
    ///
    /// The package makes up no placeholder: show your own words for an item with no name.
    public let name: String?
    /// The text of the type's body field with its Markdown removed, at most 240 code points, or `nil` where it holds
    /// no text.
    public let preview: String?

    public init(name: String?, preview: String?) {
        self.name = name
        self.preview = preview
    }

    init(_ core: MarfaCore.ItemDisplay) {
        self.init(name: core.name, preview: core.preview)
    }
}

extension Items {
    /// The name and preview of each of `inputs`, in order, from the copy's held catalog and items, with no request.
    ///
    /// One call serves many items. A type the catalog does not hold is named by the same fallback fields the server
    /// uses. An input with an ID can name a part after a host the copy holds.
    public func displays(for inputs: [ItemDisplayInput]) async throws -> [ItemDisplay] {
        let inputs = inputs.map(\.core)
        return try await holder.run { core in try core.itemDisplays(items: inputs).map(ItemDisplay.init) }
    }

    /// The name and preview of each of `items`, in order, as ``displays(for:)`` answers them.
    ///
    /// An item whose stored properties the copy cannot read (`unreadableProperties`) has no preview, but a part
    /// can still be named after its host.
    public func displays(of items: [Item]) async throws -> [ItemDisplay] {
        try await displays(for: items.map { ItemDisplayInput(type: $0.type, properties: $0.properties, id: $0.id) })
    }
}
