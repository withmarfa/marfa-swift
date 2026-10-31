/// The words around what a search found, as a list of runs of text, each marked as a match or not.
///
/// The server and the copy write an excerpt as HTML in which the text is escaped and each match is wrapped in
/// `<mark>` and `</mark>` (`search-and-filters/excerpt-escaped`, `-mark` and `-markup`). This reads that form, so an
/// app draws the runs in its own style, never matches anything itself and never renders the HTML. Where the excerpt
/// cuts the text, it holds `...` in the run beside the cut, as the contract writes it.
public struct SearchExcerpt: Sendable, Hashable {
    /// A stretch of the excerpt, all matched or all not.
    public struct Run: Sendable, Hashable {
        public var text: String
        /// Whether the search matched this text.
        public var isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    /// In order, with no empty run and no two neighbors of the same kind.
    public var runs: [Run]

    /// The excerpt without its marks.
    public var text: String { runs.map(\.text).joined() }

    public init(runs: [Run]) {
        self.runs = runs
    }

    /// Reads an excerpt in the server's HTML form.
    ///
    /// The five escapes the server writes, and any numeric character reference, read as the character they stand for;
    /// an `&` that begins no reference stays as it is. A tag other than `<mark>` and `</mark>` is dropped, which the
    /// contract never has the server write, and a `</mark>` with no `<mark>` before it marks nothing.
    public init(html: String) {
        var runs: [Run] = []
        var text = ""
        var isMatch = false

        func flush() {
            guard !text.isEmpty else { return }
            if let last = runs.last, last.isMatch == isMatch {
                runs[runs.count - 1].text += text
            } else {
                runs.append(Run(text: text, isMatch: isMatch))
            }
            text = ""
        }

        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            if character == "<", let close = html[index...].firstIndex(of: ">") {
                let name = html[html.index(after: index)..<close].lowercased()
                if name == "mark" || name == "/mark" {
                    flush()
                    isMatch = name == "mark"
                }
                index = html.index(after: close)
            } else if character == "&", let end = html[index...].prefix(12).firstIndex(of: ";"),
                let decoded = Self.reference(html[html.index(after: index)..<end])
            {
                text += decoded
                index = html.index(after: end)
            } else {
                text.append(character)
                index = html.index(after: index)
            }
        }
        flush()
        self.runs = runs
    }

    /// The character a reference names: the server's five escapes, or a decimal or hexadecimal one.
    private static func reference(_ name: Substring) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value =
                digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}

extension SearchHit {
    /// The excerpt as runs of text, marked where the search matched; ``snippet`` is the same excerpt as HTML.
    public var excerpt: SearchExcerpt { SearchExcerpt(html: snippet) }
}
