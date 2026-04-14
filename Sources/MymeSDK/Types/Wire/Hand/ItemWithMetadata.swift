import Foundation

/// An item paired with its metadata, as returned with `include=metadata`.
///
/// Composite of the generated `Item` and `Metadata`. Hand-written because
/// this envelope is built at SDK call sites rather than being emitted
/// uniformly by the server as a top-level wire shape.
public struct ItemWithMetadata: Codable, Sendable, Hashable {
    public let item: Item
    public let metadata: Metadata

    public init(item: Item, metadata: Metadata) {
        self.item = item
        self.metadata = metadata
    }
}
