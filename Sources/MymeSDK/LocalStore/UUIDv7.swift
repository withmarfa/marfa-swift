import Foundation
import Security

/// UUIDv7 generator — RFC 9562 compliant.
///
/// Layout (16 bytes):
///   - 48 bits: Unix timestamp in milliseconds (big-endian)
///   - 4 bits: version (= 7)
///   - 12 bits: random sub-millisecond entropy
///   - 2 bits: variant (= 10)
///   - 62 bits: random
///
/// Used by Myme as the canonical ID format because it is timestamp-prefixed
/// (sortable insertions, `created_at`-ordered local reads stay efficient),
/// globally unique, and client-generatable without server coordination —
/// the same property the server's UUIDv7 generator relies on.
enum UUIDv7 {
    /// Generate a fresh UUIDv7. Returns the lowercase canonical string form
    /// (`xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx`) for direct use anywhere the
    /// SDK previously emitted `UUID().uuidString.lowercased()`.
    static func generateString() -> String {
        let bytes = generateBytes()
        return formatString(bytes: bytes)
    }

    /// Generate the raw 16-byte UUIDv7 value. Useful in callers that want
    /// to bridge into `Foundation.UUID(uuid:)` directly.
    static func generateBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let now = Date().timeIntervalSince1970
        let ms = UInt64(now * 1000)

        // 48-bit timestamp (big-endian) into bytes 0..5
        bytes[0] = UInt8((ms >> 40) & 0xff)
        bytes[1] = UInt8((ms >> 32) & 0xff)
        bytes[2] = UInt8((ms >> 24) & 0xff)
        bytes[3] = UInt8((ms >> 16) & 0xff)
        bytes[4] = UInt8((ms >> 8) & 0xff)
        bytes[5] = UInt8(ms & 0xff)

        // Random for the remaining 10 bytes (6..15)
        var randBytes = [UInt8](repeating: 0, count: 10)
        let status = randBytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 10, base)
        }
        if status != errSecSuccess {
            // Fall back to Swift's PRNG; SystemRandomNumberGenerator is
            // documented as cryptographically secure on Apple platforms.
            var rng = SystemRandomNumberGenerator()
            for i in 0..<10 {
                randBytes[i] = UInt8.random(in: 0...UInt8.max, using: &rng)
            }
        }
        for i in 0..<10 {
            bytes[6 + i] = randBytes[i]
        }

        // Set version (high nibble of byte 6 = 0b0111)
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        // Set variant (high two bits of byte 8 = 0b10)
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        return bytes
    }

    private static func formatString(bytes: [UInt8]) -> String {
        // 8-4-4-4-12 hex layout
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        return "\(String(s[0..<8]))-\(String(s[8..<12]))-\(String(s[12..<16]))-\(String(s[16..<20]))-\(String(s[20..<32]))"
    }
}
