/// A strict RFC 8259 reader that keeps object key order.
///
/// It nests with an explicit stack rather than recursion, so hostile nesting
/// meets the limit instead of the end of the thread's stack.
struct JSONReader {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var offset = 0
    private var scratch: [UInt8] = []

    private init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    static func value(_ text: String) throws -> JSONValue {
        var text = text
        return try text.withUTF8 { try read($0, object: false) }
    }

    static func object(_ text: String) throws -> JSONObject {
        var text = text
        let value = try text.withUTF8 { try read($0, object: true) }
        guard case .object(let object) = value else {
            throw MarfaError.decoding(message: "invalid JSON: expected an object at byte offset 0")
        }
        return object
    }

    /// For bytes a `String` cannot hold, such as invalid UTF-8.
    static func value(bytes: [UInt8]) throws -> JSONValue {
        try bytes.withUnsafeBufferPointer { try read($0, object: false) }
    }

    private static func read(_ bytes: UnsafeBufferPointer<UInt8>, object: Bool) throws -> JSONValue {
        var reader = JSONReader(bytes)
        reader.skipWhitespace()
        if object, reader.byte != UInt8(ascii: "{") {
            throw reader.failure(reader.atEnd ? "unexpected end of input" : "expected an object")
        }
        let value = try reader.document()
        reader.skipWhitespace()
        guard reader.atEnd else { throw reader.failure("unexpected text after the value") }
        return value
    }

    private struct Frame {
        let isObject: Bool
        var elements: [JSONValue] = []
        var object = JSONObject()
        var key = ""
    }

    private var atEnd: Bool { offset >= bytes.count }

    /// The byte at the offset, or 0 at the end, which no valid token starts with.
    private var byte: UInt8 { atEnd ? 0 : bytes[offset] }

    private mutating func document() throws -> JSONValue {
        var frames: [Frame] = []
        while true {
            skipWhitespace()
            var value: JSONValue
            switch byte {
            case UInt8(ascii: "["):
                guard frames.count < JSONValue.nestingLimit else {
                    throw failure("nesting deeper than \(JSONValue.nestingLimit)")
                }
                offset += 1
                skipWhitespace()
                guard byte == UInt8(ascii: "]") else {
                    frames.append(Frame(isObject: false))
                    continue
                }
                offset += 1
                value = .array([])
            case UInt8(ascii: "{"):
                guard frames.count < JSONValue.nestingLimit else {
                    throw failure("nesting deeper than \(JSONValue.nestingLimit)")
                }
                offset += 1
                skipWhitespace()
                guard byte == UInt8(ascii: "}") else {
                    var frame = Frame(isObject: true)
                    frame.key = try key(in: frame.object)
                    frames.append(frame)
                    continue
                }
                offset += 1
                value = .object(JSONObject())
            case UInt8(ascii: "\""):
                value = .string(try string())
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                value = try number()
            case UInt8(ascii: "t"):
                try literal("true")
                value = .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                value = .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                value = .null
            default:
                throw failure(atEnd ? "unexpected end of input" : "unexpected character")
            }

            while true {
                guard !frames.isEmpty else { return value }
                let top = frames.count - 1
                skipWhitespace()
                if frames[top].isObject {
                    frames[top].object.append(frames[top].key, value)
                    if byte == UInt8(ascii: ",") {
                        offset += 1
                        skipWhitespace()
                        frames[top].key = try key(in: frames[top].object)
                        break
                    }
                    guard byte == UInt8(ascii: "}") else {
                        throw failure(atEnd ? "unexpected end of input" : "expected , or } in an object")
                    }
                    offset += 1
                    value = .object(frames.removeLast().object)
                } else {
                    frames[top].elements.append(value)
                    if byte == UInt8(ascii: ",") {
                        offset += 1
                        break
                    }
                    guard byte == UInt8(ascii: "]") else {
                        throw failure(atEnd ? "unexpected end of input" : "expected , or ] in an array")
                    }
                    offset += 1
                    value = .array(frames.removeLast().elements)
                }
            }
        }
    }

    /// A key and its colon.
    ///
    /// The core never writes a key twice in one object, so a repeated one
    /// means the text is corrupt.
    private mutating func key(in object: JSONObject) throws -> String {
        guard byte == UInt8(ascii: "\"") else {
            throw failure(atEnd ? "unexpected end of input" : "expected a string key")
        }
        let start = offset
        let key = try string()
        guard !object.contains(key) else { throw failure("duplicate key", at: start) }
        skipWhitespace()
        guard byte == UInt8(ascii: ":") else {
            throw failure(atEnd ? "unexpected end of input" : "expected : after a key")
        }
        offset += 1
        return key
    }

    private mutating func string() throws -> String {
        let start = offset
        offset += 1
        var run = offset
        var escaped = false
        scratch.removeAll(keepingCapacity: true)
        while true {
            guard !atEnd else { throw failure("unterminated string", at: start) }
            let next = bytes[offset]
            if next == UInt8(ascii: "\"") {
                break
            } else if next == UInt8(ascii: "\\") {
                scratch.append(contentsOf: bytes[run..<offset])
                escaped = true
                try escape()
                run = offset
            } else if next < 0x20 {
                throw failure("unescaped control character in a string")
            } else {
                offset += 1
            }
        }
        let end = offset
        offset += 1
        let text: String?
        if escaped {
            scratch.append(contentsOf: bytes[run..<end])
            text = String(validating: scratch, as: UTF8.self)
        } else {
            text = String(validating: UnsafeBufferPointer(rebasing: bytes[run..<end]), as: UTF8.self)
        }
        guard let text else { throw failure("invalid UTF-8 in a string", at: start) }
        return text
    }

    private mutating func escape() throws {
        let start = offset
        offset += 1
        let short: UInt8
        switch byte {
        case UInt8(ascii: "\""): short = 0x22
        case UInt8(ascii: "\\"): short = 0x5C
        case UInt8(ascii: "/"): short = 0x2F
        case UInt8(ascii: "b"): short = 0x08
        case UInt8(ascii: "f"): short = 0x0C
        case UInt8(ascii: "n"): short = 0x0A
        case UInt8(ascii: "r"): short = 0x0D
        case UInt8(ascii: "t"): short = 0x09
        case UInt8(ascii: "u"):
            offset += 1
            var value = try hex(start)
            if (0xD800...0xDBFF).contains(value) {
                guard byte == UInt8(ascii: "\\"), offset + 1 < bytes.count, bytes[offset + 1] == UInt8(ascii: "u")
                else { throw failure("high surrogate without a low surrogate", at: start) }
                offset += 2
                let low = try hex(start)
                guard (0xDC00...0xDFFF).contains(low) else {
                    throw failure("high surrogate without a low surrogate", at: start)
                }
                value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(value) {
                throw failure("low surrogate without a high surrogate", at: start)
            }
            guard let scalar = Unicode.Scalar(value) else { throw failure("invalid escape", at: start) }
            UTF8.encode(scalar) { scratch.append($0) }
            return
        default:
            throw failure(atEnd ? "unterminated string" : "invalid escape", at: start)
        }
        scratch.append(short)
        offset += 1
    }

    private mutating func hex(_ escape: Int) throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw failure("invalid \\u escape", at: escape)
            }
            value = value << 4 | UInt32(digit)
            offset += 1
        }
        return value
    }

    /// An integer `Int64` holds reads exact, whatever form the literal takes,
    /// so `1.0`, `1e2` and `9007199254740993.0` are integers; anything else
    /// is the nearest `Double`.
    private mutating func number() throws -> JSONValue {
        let start = offset
        let negative = byte == UInt8(ascii: "-")
        if negative { offset += 1 }

        guard isDigit(byte) else { throw failure("expected a digit", at: offset) }
        let integerStart = offset
        if byte == UInt8(ascii: "0") {
            offset += 1
            guard !isDigit(byte) else { throw failure("leading zero in a number", at: start) }
        } else {
            while isDigit(byte) { offset += 1 }
        }
        let integerEnd = offset

        var fractionStart = offset
        var fractionEnd = offset
        if byte == UInt8(ascii: ".") {
            offset += 1
            guard isDigit(byte) else { throw failure("expected a digit after the decimal point") }
            fractionStart = offset
            while isDigit(byte) { offset += 1 }
            fractionEnd = offset
        }

        var exponent = 0
        var hasExponent = false
        if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
            hasExponent = true
            offset += 1
            let negativeExponent = byte == UInt8(ascii: "-")
            if negativeExponent || byte == UInt8(ascii: "+") { offset += 1 }
            guard isDigit(byte) else { throw failure("expected a digit in the exponent") }
            while isDigit(byte) {
                // Far past any Double's range, and small enough not to overflow.
                if exponent < 100_000_000 { exponent = exponent * 10 + Int(byte - UInt8(ascii: "0")) }
                offset += 1
            }
            if negativeExponent { exponent = -exponent }
        }

        if fractionStart == fractionEnd, !hasExponent,
            let value = exact(bytes[integerStart..<integerEnd], scale: 0, negative: negative)
        {
            return .integer(value)
        }
        if fractionStart != fractionEnd || hasExponent {
            var digits = Array(bytes[integerStart..<integerEnd]) + bytes[fractionStart..<fractionEnd]
            var scale = exponent - (fractionEnd - fractionStart)
            while digits.last == UInt8(ascii: "0") {
                digits.removeLast()
                scale += 1
            }
            let significant = digits.drop { $0 == UInt8(ascii: "0") }
            if significant.isEmpty { return .integer(0) }
            if scale >= 0, significant.count + scale <= 19,
                let value = exact(significant, scale: scale, negative: negative)
            {
                return .integer(value)
            }
        }

        let literal = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<offset]), as: UTF8.self)
        guard let value = Double(literal), value.isFinite else {
            throw failure("number too large for a Double", at: start)
        }
        return .number(value)
    }

    /// Accumulates downward, so `Int64.min` fits.
    private func exact(_ digits: some Collection<UInt8>, scale: Int, negative: Bool) -> Int64? {
        var value: Int64 = 0
        var overflow = false
        for digit in digits {
            (value, overflow) = value.multipliedReportingOverflow(by: 10)
            if overflow { return nil }
            (value, overflow) = value.subtractingReportingOverflow(Int64(digit - UInt8(ascii: "0")))
            if overflow { return nil }
        }
        for _ in 0..<scale {
            (value, overflow) = value.multipliedReportingOverflow(by: 10)
            if overflow { return nil }
        }
        if negative { return value }
        return value == .min ? nil : -value
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private mutating func literal(_ word: StaticString) throws {
        let start = offset
        let expected = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
        guard bytes.count - offset >= expected.count, bytes[offset..<offset + expected.count].elementsEqual(expected)
        else { throw failure("unexpected character", at: start) }
        offset += expected.count
    }

    private mutating func skipWhitespace() {
        while !atEnd {
            switch bytes[offset] {
            case 0x20, 0x09, 0x0A, 0x0D: offset += 1
            default: return
            }
        }
    }

    private func failure(_ problem: String, at position: Int? = nil) -> MarfaError {
        .decoding(message: "invalid JSON: \(problem) at byte offset \(position ?? offset)")
    }
}

/// Compact JSON with object keys in order and strings escaped minimally.
///
/// Like the reader, it nests with an explicit stack rather than recursion.
struct JSONWriter {
    private static let hexDigits = Array("0123456789abcdef".utf8)
    private var output: [UInt8] = []
    private let describing: Bool

    private init(describing: Bool) {
        self.describing = describing
    }

    private enum Open {
        case array([JSONValue], next: Int)
        case object(JSONObject, next: Int)

        /// The index or key of the member being written.
        var current: String {
            switch self {
            case .array(_, let next): String(next - 1)
            case .object(let object, let next): object.keys[next - 1]
            }
        }
    }

    private struct Unwritable: Error {
        let path: [String]
        let problem: String
    }

    static func text(_ value: JSONValue) throws -> String {
        var writer = JSONWriter(describing: false)
        do {
            try writer.write(value)
        } catch let error as Unwritable {
            let path = error.path.isEmpty ? "the value" : error.path.joined(separator: ".")
            throw MarfaError.invalid(message: "\(path) cannot be written as JSON: \(error.problem)")
        }
        return String(decoding: writer.output, as: UTF8.self)
    }

    static func description(_ value: JSONValue) -> String {
        var writer = JSONWriter(describing: true)
        try? writer.write(value)
        return String(decoding: writer.output, as: UTF8.self)
    }

    private mutating func write(_ value: JSONValue) throws {
        var open: [Open] = []
        var pending: JSONValue? = value
        while true {
            if let value = pending {
                pending = nil
                switch value {
                case .null: output.append(contentsOf: "null".utf8)
                case .bool(let value): output.append(contentsOf: (value ? "true" : "false").utf8)
                case .integer(let value): output.append(contentsOf: String(value).utf8)
                case .number(let value):
                    guard value.isFinite || describing else {
                        throw Unwritable(path: open.map(\.current), problem: "\(value) is not a finite number")
                    }
                    // Swift's shortest round-trip form, such as 0.1, 1e-05 or 5e+20, is valid JSON.
                    output.append(contentsOf: value.description.utf8)
                case .string(let value): write(value)
                case .array(let elements):
                    output.append(UInt8(ascii: "["))
                    open.append(.array(elements, next: 0))
                case .object(let object):
                    output.append(UInt8(ascii: "{"))
                    open.append(.object(object, next: 0))
                }
            }

            guard let top = open.last else { return }
            switch top {
            case .array(let elements, let next):
                guard next < elements.count else {
                    output.append(UInt8(ascii: "]"))
                    open.removeLast()
                    continue
                }
                if next > 0 { output.append(UInt8(ascii: ",")) }
                open[open.count - 1] = .array(elements, next: next + 1)
                pending = elements[next]
            case .object(let object, let next):
                guard next < object.count else {
                    output.append(UInt8(ascii: "}"))
                    open.removeLast()
                    continue
                }
                if next > 0 { output.append(UInt8(ascii: ",")) }
                write(object.keys[next])
                output.append(UInt8(ascii: ":"))
                open[open.count - 1] = .object(object, next: next + 1)
                pending = object.values[next]
            }
        }
    }

    private mutating func write(_ string: String) {
        output.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case 0x22: output.append(contentsOf: #"\""#.utf8)
            case 0x5C: output.append(contentsOf: #"\\"#.utf8)
            case 0x08: output.append(contentsOf: #"\b"#.utf8)
            case 0x0C: output.append(contentsOf: #"\f"#.utf8)
            case 0x0A: output.append(contentsOf: #"\n"#.utf8)
            case 0x0D: output.append(contentsOf: #"\r"#.utf8)
            case 0x09: output.append(contentsOf: #"\t"#.utf8)
            case 0x00..<0x20:
                output.append(contentsOf: #"\u00"#.utf8)
                output.append(Self.hexDigits[Int(byte >> 4)])
                output.append(Self.hexDigits[Int(byte & 0x0F)])
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }
}
