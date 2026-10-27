import Foundation

/// What draws a type's icon: the SF Symbol for a Lucide name, Lucide's own artwork for a name with no SF Symbol
/// that suits it, or a fallback.
public enum TypeIconArtwork: Sendable, Hashable {
    /// An SF Symbol that stands for the Lucide name.
    case symbol(String)
    /// The Lucide icon of this name, drawn from the artwork the package ships.
    case lucide(String)
    /// An SF Symbol for a type with no icon, and for a name this package does not know: a server newer than the
    /// SDK can send one.
    case fallback

    /// The SF Symbol drawn for ``fallback``.
    public static let fallbackSymbol = "square.dashed"

    /// The artwork for a Lucide name, such as `book-open`, or for `nil` when no type in a chain sets an icon.
    public init(name: String?) {
        guard let name else {
            self = .fallback
            return
        }
        if let symbol = LucideSymbols.table[name] {
            self = .symbol(symbol)
        } else if Self.drawn.contains(name) {
            self = .lucide(name)
        } else {
            self = .fallback
        }
    }

    /// The pinned names with no SF Symbol, each shipped as artwork.
    static let drawn: Set<String> = Set(LucidePinned.names).subtracting(LucideSymbols.table.keys)

    static let bundle = Bundle.module

    /// The name of the template image in this package's asset catalog.
    static func assetName(_ name: String) -> String { "lucide-\(name)" }
}
