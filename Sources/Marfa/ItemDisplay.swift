import Foundation
internal import MarfaCore

/// What an app shows for an item that is not yet saved, or whose type it reads from a draft: the item's type and its properties.
public struct ItemDisplayInput: Sendable, Hashable {
    public var type: String
    public var properties: JSONObject

    public init(type: String, properties: JSONObject) {
        self.type = type
        self.properties = properties
    }

    var core: MarfaCore.ItemDisplayInput { MarfaCore.ItemDisplayInput(type: type, properties: properties.core) }
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
    /// The name and preview of each of `inputs`, in order, from the copy's catalog alone, with no request.
    ///
    /// One call serves many items. A type the catalog does not hold is named by the same fallback fields the server
    /// uses.
    public func displays(for inputs: [ItemDisplayInput]) async throws -> [ItemDisplay] {
        let inputs = inputs.map(\.core)
        return try await holder.run { core in try core.itemDisplays(items: inputs).map(ItemDisplay.init) }
    }

    /// The name and preview of each of `items`, in order, as ``displays(for:)`` answers them.
    ///
    /// An item whose stored properties the copy cannot read (`unreadableProperties`) has no name and no preview.
    public func displays(of items: [Item]) async throws -> [ItemDisplay] {
        try await displays(for: items.map { ItemDisplayInput(type: $0.type, properties: $0.properties) })
    }
}
