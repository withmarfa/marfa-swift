#if DEBUG
import Foundation

/// The text shapes the core accepts for an `email`, `date` or `datetime` value, judged byte for byte.
enum Formats {
    static func email(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let at = bytes.firstIndex(of: UInt8(ascii: "@")) else { return false }
        let local = bytes[..<at]
        let domain = bytes[(at + 1)...]
        func localEnd(_ byte: UInt8) -> Bool { alphanumeric(byte) || "_+-".utf8.contains(byte) }
        guard let last = local.last, local.first != UInt8(ascii: "."),
            !zip(bytes, bytes.dropFirst()).contains(where: { $0 == UInt8(ascii: ".") && $1 == UInt8(ascii: ".") }),
            local.allSatisfy({ localEnd($0) || "'.".utf8.contains($0) }), localEnd(last)
        else { return false }
        var parts = domain.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard let tld = parts.popLast(), tld.count >= 2,
            tld.allSatisfy(letter),
            !parts.isEmpty
        else { return false }
        return parts.allSatisfy { label in
            guard let first = label.first, alphanumeric(first) else { return false }
            return label.allSatisfy { alphanumeric($0) || $0 == UInt8(ascii: "-") }
        }
    }

    static func date(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
            let year = digits(bytes[0..<4]), let month = digits(bytes[5..<7]), let day = digits(bytes[8..<10])
        else { return false }
        let days =
            switch month {
            case 1, 3, 5, 7, 8, 10, 12: 31
            case 4, 6, 9, 11: 30
            case 2 where year % 4 == 0 && (year % 100 != 0 || year % 400 == 0): 29
            case 2: 28
            default: 0
            }
        return day > 0 && day <= days
    }

    static func datetime(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count >= 17, bytes[10] == UInt8(ascii: "T"), date(String(decoding: bytes[..<10], as: UTF8.self))
        else { return false }
        let end: Int
        if bytes.last == UInt8(ascii: "Z") {
            end = bytes.count - 1
        } else {
            let at = bytes.count - 6
            guard bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-"), bytes[at + 3] == UInt8(ascii: ":"),
                digits(bytes[(at + 1)..<(at + 3)]).map({ $0 < 24 }) == true,
                digits(bytes[(at + 4)...]).map({ $0 < 60 }) == true
            else { return false }
            end = at
        }
        let time = Array(bytes[11..<end])
        guard time.count >= 5, time[2] == UInt8(ascii: ":"), digits(time[..<2]).map({ $0 < 24 }) == true,
            digits(time[3..<5]).map({ $0 < 60 }) == true
        else { return false }
        if time.count == 5 { return true }
        guard time.count >= 8, time[5] == UInt8(ascii: ":"), digits(time[6..<8]).map({ $0 < 60 }) == true
        else { return false }
        if time.count == 8 { return true }
        return time[8] == UInt8(ascii: ".") && time.count > 9
            && time[9...].allSatisfy(digit)
    }

    private static func digit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }

    private static func letter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    private static func alphanumeric(_ byte: UInt8) -> Bool { digit(byte) || letter(byte) }

    private static func digits(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard !bytes.isEmpty, bytes.allSatisfy(digit) else {
            return nil
        }
        return bytes.reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
    }
}
#endif
