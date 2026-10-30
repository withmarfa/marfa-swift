import Foundation
import MarfaIcons

/// The brand marks of the Simple Icons release Marfa pins, as a product of their own so that an app that does not
/// link it ships none of the artwork.
///
/// Call ``register()`` once at launch, before any `TypeIcon` draws. From then on a `simple-icons:` ID draws its mark
/// as a template image, which tints with `foregroundStyle` like the rest. Without the call, or without this
/// product, such an ID draws the fallback.
public enum MarfaBrandIcons {
    /// Makes the artwork this product ships the source of brand marks for `TypeIcon` and `Image(typeIcon:)`.
    public static func register() {
        artwork.register()
    }

    /// The release of `@iconify-json/simple-icons` the artwork comes from.
    public static var version: String { SimpleIconsIconSet.version }

    /// Every icon ID the server accepts from that release, each `simple-icons:<name>`.
    public static var ids: [String] { SimpleIconsIconSet.ids }

    static let bundle = Bundle.module

    static let artwork = BrandArtwork(bundle: bundle, ids: SimpleIconsIconSet.ids)
}
