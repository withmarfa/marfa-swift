import Marfa
import SwiftUI

extension Image {
    /// The image for a type's icon, given as an Iconify ID such as `lucide:book-open`.
    ///
    /// It is the SF Symbol that stands for a `lucide:` ID, else Lucide's own artwork as a template image, else a
    /// fallback symbol. A `simple-icons:` ID draws its brand mark when `MarfaBrandIcons` is registered. It tints
    /// like a symbol, with `foregroundStyle`.
    ///
    /// Artwork has no font to scale with, so this image has its natural size of 24 points; ``TypeIcon`` sizes it to
    /// sit beside text.
    public init(typeIcon id: String?) {
        let brand = BrandArtwork.current
        self.init(artwork: TypeIconArtwork(id: id, brand: brand), brand: brand)
    }

    init(artwork: TypeIconArtwork, brand: BrandArtwork?) {
        switch artwork {
        case .symbol(let symbol): self.init(systemName: symbol)
        case .lucide(let id): self = Image(TypeIconArtwork.assetName(id), bundle: .module).renderingMode(.template)
        case .brand(let id):
            guard let brand else {
                self.init(systemName: TypeIconArtwork.fallbackSymbol)
                return
            }
            self = Image(BrandArtwork.assetName(id), bundle: brand.bundle).renderingMode(.template)
        case .fallback: self.init(systemName: TypeIconArtwork.fallbackSymbol)
        }
    }
}

/// A type's icon, drawn as an SF Symbol where one suits the `lucide:` ID and from artwork where none does.
///
/// Both tint with `foregroundStyle` and follow light and dark appearance, and both size with the surrounding font
/// and Dynamic Type. A `nil` ID, a bare name, an unknown set or name, and a `simple-icons:` ID with no brand artwork
/// registered draw a fallback and never fail.
public struct TypeIcon: View {
    private let id: String?
    @ScaledMetric(relativeTo: .body) private var drawnSize: CGFloat = 17

    /// `id` is an Iconify ID such as `lucide:book-open`, as `ItemType.icon` holds it; `nil` draws the fallback.
    public init(id: String?) {
        self.id = id
    }

    public init(_ type: ItemType) {
        self.init(id: type.icon)
    }

    public var body: some View {
        let brand = BrandArtwork.current
        let artwork = TypeIconArtwork(id: id, brand: brand)
        let image = Image(artwork: artwork, brand: brand)
        switch artwork {
        case .lucide, .brand:
            image.resizable().aspectRatio(contentMode: .fit).frame(width: drawnSize, height: drawnSize)
        case .symbol, .fallback:
            image
        }
    }
}
