import Foundation
import Synchronization

/// Artwork for `simple-icons:` brand marks, supplied by a product other than this one so that an app that does not
/// link it ships none.
///
/// An app does not make one; it calls `MarfaBrandIcons.register()` once at launch, before any ``TypeIcon`` draws.
public struct BrandArtwork: Sendable {
    let bundle: Bundle
    let ids: Set<String>

    /// Draws the icons named by `ids` from the asset catalog in `bundle`, where each is an image named like the ID
    /// with the colon a hyphen: `simple-icons-github`.
    public init(bundle: Bundle, ids: some Sequence<String>) {
        self.bundle = bundle
        self.ids = Set(ids)
    }

    private static let registered = Mutex<BrandArtwork?>(nil)

    static var current: BrandArtwork? { registered.withLock { $0 } }

    /// Makes this the source of brand marks for every ``TypeIcon`` and `Image(typeIcon:)`.
    ///
    /// Until it is called, a `simple-icons:` ID draws the fallback. A later call replaces an earlier one.
    public func register() {
        Self.registered.withLock { $0 = self }
    }

    /// The name of the template image in the catalog for an icon ID such as `simple-icons:github`.
    static func assetName(_ id: String) -> String { id.replacing(":", with: "-") }
}
