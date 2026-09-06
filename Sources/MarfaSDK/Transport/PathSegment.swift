import Foundation

extension String {

    /// This string escaped to occupy exactly one segment of a request path.
    ///
    /// **A path encoder is not a segment encoder, and the gap between them is
    /// silent.** `CharacterSet.urlPathAllowed` keeps `/`, because a path is
    /// allowed to hold separators — so an identifier encoded with it still
    /// splits into two segments, and the request succeeds against a route the
    /// caller never named. A `#` truncates the path into a fragment and a `?`
    /// opens a query string the same way.
    ///
    /// **Nothing refuses any of it.** `URLComponents(string:)` parses rather
    /// than encodes, but it also repairs: a space and a bare percent are
    /// escaped for you and the rest is parsed as written, so a raw segment
    /// yields a valid URL addressing something else rather than an error
    /// anyone could act on. Measured on Swift 6.3.3 / macOS 26.6 on 6
    /// September 2026; `PathSegmentTransportTests` pins it.
    ///
    /// The escaped set is JavaScript's `encodeURIComponent`, byte for byte,
    /// because the platform's TypeScript client uses that and an identifier
    /// handed to both kits has to produce the same request from either. RFC
    /// 3986 would leave `:`, `@` and the sub-delimiters unescaped; escaping
    /// them costs nothing, since a server decodes either spelling, while the
    /// two clients disagreeing about what an id may contain is the defect this
    /// closes.
    ///
    /// Encoding runs over UTF-8 bytes rather than through
    /// `addingPercentEncoding(withAllowedCharacters:)`, which is optional and
    /// so needs a fallback at every use. The only fallback available is the
    /// unescaped string — this defect, restored silently, in the branch nobody
    /// can reach to test.
    var escapedPathSegment: String {
        var escaped = ""
        escaped.reserveCapacity(utf8.count)
        for byte in utf8 {
            if Self.unescapedSegmentBytes.contains(byte) {
                escaped.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                escaped.append("%")
                escaped.append(Self.hexDigits[Int(byte >> 4)])
                escaped.append(Self.hexDigits[Int(byte & 0x0F)])
            }
        }
        return escaped
    }

    /// `encodeURIComponent`'s unescaped set: the unreserved characters of RFC
    /// 3986 plus the four marks ECMA-262 kept from RFC 2396.
    ///
    /// Spelled as bytes rather than as a `CharacterSet` so that a non-ASCII
    /// scalar is escaped as its UTF-8 bytes. `CharacterSet.alphanumerics`
    /// admits every Unicode letter, which would leave an accented identifier
    /// on the wire unescaped where the TypeScript client percent-encodes it.
    private static let unescapedSegmentBytes: Set<UInt8> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8
    )

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")
}
