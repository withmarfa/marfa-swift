import Foundation
import Testing

@testable import Marfa

/// Rows written straight into a store, with values a local create can't make, read through the packed listing and
/// through UniFFI's record of one item, which must agree to the bit.
///
/// The seeds run one at a time: reading megabyte rows keeps a thread busy for a second or more on a small runner, and
/// four at once would take every core from the suites that time themselves.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PackedListingDifferential {
    /// SplitMix64, so a failure names a seed that reproduces it.
    struct Random {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func chance(_ inN: Int) -> Bool { below(inN) == 0 }
        mutating func pick<T>(_ from: [T]) -> T { from[below(from.count)] }

        mutating func scalar() -> Unicode.Scalar {
            while true {
                let ranges: [ClosedRange<UInt32>] = [0...0x7F, 0x80...0x7FF, 0x800...0xFFFF, 0x1_0000...0x10_FFFF]
                let range = pick(ranges)
                let value = range.lowerBound + UInt32(next() % UInt64(range.count))
                if let scalar = Unicode.Scalar(value) { return scalar }
            }
        }

        mutating func text(most: Int = 24) -> String {
            var text = String.UnicodeScalarView()
            for _ in 0..<below(most + 1) { text.append(scalar()) }
            return String(text)
        }
    }

    static func hex(_ text: String) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count * 2)
        for byte in text.utf8 {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0xF)])
        }
        return "CAST(X'" + String(decoding: out, as: UTF8.self) + "' AS TEXT)"
    }

    static func json(_ text: String, _ random: inout Random) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            case _ where scalar.value > 0xFFFF && random.chance(3):
                let v = scalar.value - 0x1_0000
                out += String(format: "\\u%04x\\u%04x", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
            case _ where scalar.value <= 0xFFFF && random.chance(8): out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static let numbers = [
        "0", "-0", "-0.0", "0e0", "1E2", "1e-400", "5e-324", "-5e-324", "2.2250738585072014e-308",
        "1.7976931348623157e308", "-1.7976931348623157e308", "9223372036854775807", "-9223372036854775808",
        "9223372036854775808", "-9223372036854775809", "18446744073709551615", "123456789012345678901234567890",
        "9007199254740993", "0.1", "1.0", "-1.5e-7",
    ]

    static func value(_ random: inout Random, depth: Int) -> String {
        let deeper = depth < 62 && random.below(depth + 2) < 2
        switch random.below(deeper ? 9 : 7) {
        case 0: return "null"
        case 1: return random.chance(2) ? "true" : "false"
        case 2: return String(Int64(bitPattern: random.next()))
        case 3: return random.pick(numbers)
        case 4:
            while true {
                let double = Double(bitPattern: random.next())
                if double.isFinite { return "\(double)" }
            }
        case 5, 6: return json(random.text(), &random)
        case 7:
            return "[" + (0..<random.below(5)).map { _ in value(&random, depth: depth + 1) }.joined(separator: ",")
                + "]"
        default: return object(&random, depth: depth + 1, most: 5)
        }
    }

    static func object(_ random: inout Random, depth: Int, most: Int) -> String {
        var members: [String] = []
        for _ in 0..<random.below(most + 1) {
            let key = random.chance(6) ? random.pick(["title", "body", ""]) : random.text(most: 8)
            members.append(json(key, &random) + ":" + value(&random, depth: depth))
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    /// The SQL for a row's stored properties.
    static func properties(_ random: inout Random) -> String {
        switch random.below(40) {
        case 0: return hex("{\"title\":")
        case 1: return hex("[1]")
        case 2: return hex("{\"t\":\"\\ud800\"}")
        case 3: return hex("{\"t\":1e400}")
        case 4: return hex(String(repeating: "[", count: 200) + String(repeating: "]", count: 200))
        case 5:
            let deep = String(repeating: "[", count: 62) + "null" + String(repeating: "]", count: 62)
            return hex("{\"deep\":\(deep)}")
        // A title of a million `x`s, built by SQLite: written out in the script, a few megabyte rows take seconds of
        // processor time in a debug build, enough on a three-core runner to hold up the suites that time themselves.
        case 6: return "'{\"title\":\"' || replace(hex(zeroblob(500000)), '0', 'x') || '\",\"body\":\"\"}'"
        default: return hex(object(&random, depth: 0, most: 12))
        }
    }

    static func optionalReal(_ random: inout Random) -> String {
        random.pick([
            "NULL", "NULL", "-0.0", "9e999", "-9e999", "51.5", "4.9e-324", "\(Double(random.below(180)) - 90.25)",
        ])
    }

    /// The SQL that writes 150 random rows and their tags.
    static func script(seed: UInt64) -> String {
        var random = Random(state: seed)
        var statements: [String] = []
        for index in 0..<150 {
            let id = "r\(index)-" + random.text(most: 6)
            let state = random.pick(["active", "archived", "revoked"])
            let tier = random.pick(["NULL", "'library'", "'feed'"])
            let type = random.chance(5) ? Self.hex(random.text(most: 10)) : "'core.note'"
            let sourceId = random.chance(2) ? "NULL" : Self.hex(random.text())
            let at = { (r: inout Random) in
                String(format: "'2026-%02d-%02dT00:00:00Z'", 1 + r.below(12), 1 + r.below(28))
            }
            statements.append(
                """
                INSERT INTO items (id,type,state,tier,version,schema_version,source,source_id,occurred_at,created_at,
                updated_at,properties,capture_latitude,capture_longitude) VALUES (\(Self.hex(id)),\(type),'\(state)',\(tier),
                \(Int64(bitPattern: random.next())),\(random.pick([Int64.min, Int64.max, 0, -1, 2])),\(Self.hex(random.text())),
                \(sourceId),\(at(&random)),\(at(&random)),\(at(&random)),\(Self.properties(&random)),\(Self.optionalReal(&random)),
                \(Self.optionalReal(&random)))
                """)
            for tag in Set((0..<random.below(5)).map { _ in random.text(most: 6) }) {
                statements.append("INSERT INTO tags (item_id, tag) VALUES (\(Self.hex(id)),\(Self.hex(tag)))")
            }
        }
        return "BEGIN;" + statements.joined(separator: ";\n") + ";COMMIT;"
    }

    @Test(arguments: [UInt64(1), 2, 3, 0xC0FFEE])
    func randomRowsReadFromTheListingAsUniFFIReadsEachAlone(seed: UInt64) async throws {
        let store = temporaryStore()
        let copy = try await WorkingCopy.open(store: store)
        _ = try await copy.items.create(Draft(type: "core.note", properties: ["title": "seed"]))
        await copy.close()

        // Off the cooperative pool: SQLite writing megabyte rows is long synchronous work.
        try await background { try PropertyValues.damage(store, Self.script(seed: seed)) }

        let reopened = try await WorkingCopy.open(store: store)
        let listed = try await reopened.items.list(ListFilters(allStates: true))
        #expect(listed.count == 151, "seed \(seed)")
        let batch = try await reopened.items.get(listed.map(\.id), includingBin: true)
        #expect(batch.rows == listed.rows, "seed \(seed)")
        var unreadable = 0
        for item in listed {
            let alone = try #require(try await reopened.items.get(item.id), "seed \(seed), \(item.id)")
            #expect(alone == item, "seed \(seed), \(item.id)")
            #expect(PackedRows.pack([alone]) == PackedRows.pack([item]), "seed \(seed), \(item.id) differs in its bits")
            if item.unreadableProperties != nil { unreadable += 1 }
        }
        #expect(unreadable > 0, "seed \(seed) made no unreadable row")
        await reopened.close()
    }
}
