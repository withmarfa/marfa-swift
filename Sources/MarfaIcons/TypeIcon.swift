import Marfa
import SwiftUI

extension Image {
    /// The image for a type's icon, given as a Lucide name.
    ///
    /// It is the SF Symbol that stands for the name, else Lucide's own artwork as a template image, else a fallback
    /// symbol. It tints like a symbol, with `foregroundStyle`.
    ///
    /// Lucide's artwork has no font to scale with, so this image has its natural size of 24 points; ``TypeIcon``
    /// sizes it to sit beside text.
    public init(typeIcon name: String?) {
        switch TypeIconArtwork(name: name) {
        case .symbol(let symbol): self.init(systemName: symbol)
        case .lucide(let name): self = Image(TypeIconArtwork.assetName(name), bundle: .module).renderingMode(.template)
        case .fallback: self.init(systemName: TypeIconArtwork.fallbackSymbol)
        }
    }
}

/// A type's icon, drawn as an SF Symbol where one suits the Lucide name and from Lucide's artwork where none does.
///
/// Both tint with `foregroundStyle` and follow light and dark appearance, and both size with the surrounding font
/// and Dynamic Type. A `nil` name, and a name this version of the package does not know, draw a fallback and never
/// fail.
public struct TypeIcon: View {
    private let name: String?
    @ScaledMetric(relativeTo: .body) private var drawnSize: CGFloat = 17

    /// `name` is a Lucide name, such as `ItemType.icon`; `nil` draws the fallback.
    public init(name: String?) {
        self.name = name
    }

    public init(_ type: ItemType) {
        self.init(name: type.icon)
    }

    public var body: some View {
        if case .lucide = TypeIconArtwork(name: name) {
            Image(typeIcon: name).resizable().aspectRatio(contentMode: .fit).frame(width: drawnSize, height: drawnSize)
        } else {
            Image(typeIcon: name)
        }
    }
}
