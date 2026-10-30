import Foundation

/// What draws a type's icon: the SF Symbol for a `lucide:` ID, Lucide's own artwork for an ID with no SF Symbol that
/// suits it, a brand mark for a `simple-icons:` ID, or a fallback.
public enum TypeIconArtwork: Sendable, Hashable {
    /// An SF Symbol that stands for the `lucide:` ID.
    case symbol(String)
    /// The Lucide icon of this ID, drawn from the artwork the package ships.
    case lucide(String)
    /// The Simple Icons mark of this ID, drawn from the artwork a registered ``BrandArtwork`` supplies.
    case brand(String)
    /// An SF Symbol for a type with no icon, and for an ID this package cannot draw: a bare name, an unknown set, an
    /// unknown name, or a brand mark when no brand artwork is registered. A server newer than the SDK can send an
    /// ID the package does not know.
    case fallback

    /// The SF Symbol drawn for ``fallback``.
    public static let fallbackSymbol = "square.dashed"

    /// The artwork for an Iconify ID such as `lucide:book-open`, or for `nil` when no type in a chain sets an icon.
    public init(id: String?) {
        self.init(id: id, brand: BrandArtwork.current)
    }

    init(id: String?, brand: BrandArtwork?) {
        guard let id else {
            self = .fallback
            return
        }
        if let symbol = LucideSymbols.table[id] {
            self = .symbol(symbol)
        } else if Self.drawn.contains(id) {
            self = .lucide(id)
        } else if brand?.ids.contains(id) == true {
            self = .brand(id)
        } else {
            self = .fallback
        }
    }

    /// The pinned Lucide IDs with no SF Symbol, each shipped as artwork.
    static let drawn: Set<String> = Set(LucideIconSet.ids).subtracting(LucideSymbols.table.keys)

    static let bundle = Bundle.module

    /// The name of the template image in this package's asset catalog.
    static func assetName(_ id: String) -> String { BrandArtwork.assetName(id) }
}
