import Foundation
package import MarfaCore

/// A listing's items cross from the core packed into one buffer, because UniFFI's generated reader costs several
/// microseconds a field-heavy record. The layout is the one `core/bindings/swift/src/packed.rs` in withmarfa/marfa
/// states and writes; the `PackedListing` tests hold the bytes both sides agree on.
extension MarfaCore.Listing {
    var answer: Rows<Item> {
        get throws(MarfaError) { Rows(try PackedRows.items(rows), completeness: Completeness(completeness)) }
    }

    /// A listing of `items`, packed as the core packs one, for a core written in Swift.
    package init(items: [Item], completeness: Marfa.Completeness) {
        self.init(rows: PackedRows.pack(items), completeness: completeness.core)
    }

    /// The same for a core written in Swift that holds the core's own rows.
    package init(items: [MarfaCore.Item], completeness: MarfaCore.Completeness) {
        self.init(rows: PackedRows.pack(items.map(Item.init)), completeness: completeness)
    }
}

enum PackedRows {
    /// The layout's version, `FORMAT` in the core's `packed.rs`.
    static let format = 2

    /// The fewest bytes an item takes: an empty ID, type, properties and source, no options and no tags.
    static let smallestItem = 56

    static func items(_ rows: Data) throws(MarfaError) -> [Item] {
        let read: Result<[Item], MarfaError> = rows.withUnsafeBytes { bytes in
            var reader = Reader(bytes: bytes)
            do throws(MarfaError) {
                let format = try reader.count()
                guard format == Self.format else {
                    throw MarfaError.decoding(
                        message: "invalid listing from the core: format \(format), where this package reads format "
                            + "\(Self.format)")
                }
                let count = try reader.count()
                var items: [Item] = []
                items.reserveCapacity(min(count, bytes.count / Self.smallestItem))
                for _ in 0..<count { items.append(try reader.item()) }
                guard reader.offset == bytes.count else { throw reader.failure("bytes after the last item") }
                return .success(items)
            } catch {
                return .failure(error)
            }
        }
        return try read.get()
    }

    static func pack(_ items: [Item]) -> Data {
        var writer = Writer()
        writer.count(format)
        writer.count(items.count)
        for item in items { writer.item(item) }
        return writer.bytes
    }

    struct Reader {
        let bytes: UnsafeRawBufferPointer
        var offset = 0
        var depth = 0

        func failure(_ reason: String) -> MarfaError {
            .decoding(message: "invalid listing from the core: \(reason) at byte offset \(offset)")
        }

        private mutating func advance(_ length: Int) throws(MarfaError) -> Int {
            guard length <= bytes.count - offset else { throw failure("it ends part way through an item") }
            defer { offset += length }
            return offset
        }

        mutating func byte() throws(MarfaError) -> UInt8 {
            bytes[try advance(1)]
        }

        mutating func count() throws(MarfaError) -> Int {
            Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: try advance(4), as: UInt32.self)))
        }

        mutating func int64() throws(MarfaError) -> Int64 {
            Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: try advance(8), as: Int64.self))
        }

        mutating func double() throws(MarfaError) -> Double {
            let bits = bytes.loadUnaligned(fromByteOffset: try advance(8), as: UInt64.self)
            return Double(bitPattern: UInt64(littleEndian: bits))
        }

        mutating func text() throws(MarfaError) -> String {
            let length = try count()
            let start = try advance(length)
            return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<start + length]), as: UTF8.self)
        }

        mutating func optional<T>(_ read: (inout Reader) throws(MarfaError) -> T) throws(MarfaError) -> T? {
            switch try byte() {
            case 0: return nil
            case 1: return try read(&self)
            case let mark: throw failure("an optional marked \(mark)")
            }
        }

        mutating func item() throws(MarfaError) -> Item {
            let id = try text()
            let type = try text()
            let properties = try object()
            let state: ItemState =
                switch try byte() {
                case 0: .active
                case 1: .archived
                case 2: .trashed
                case 3: .revoked
                case let mark: throw failure("a state marked \(mark)")
                }
            let tier: Tier? =
                switch try byte() {
                case 0: nil
                case 1: .library
                case 2: .feed
                case let mark: throw failure("a tier marked \(mark)")
                }
            let version = try int64()
            let schemaVersion = try int64()
            let source = try text()
            let sourceId = try optional { reader throws(MarfaError) in try reader.text() }
            let occurredAt = try text()
            let createdAt = try text()
            let updatedAt = try text()
            let tagCount = try count()
            var tags: [String] = []
            tags.reserveCapacity(min(tagCount, (bytes.count - offset) / 4))
            for _ in 0..<tagCount { tags.append(try text()) }
            let latitude = try optional { reader throws(MarfaError) in try reader.double() }
            let longitude = try optional { reader throws(MarfaError) in try reader.double() }
            let trashedAt = try optional { reader throws(MarfaError) in try reader.text() }
            let title = try optional { reader throws(MarfaError) in try reader.text() }
            let body = try optional { reader throws(MarfaError) in try reader.text() }
            let unreadable = try optional { reader throws(MarfaError) in try reader.text() }
            return Item(
                id: id, type: type, properties: properties, state: state, tier: tier, version: version,
                schemaVersion: schemaVersion, source: source, sourceId: sourceId, occurredAt: occurredAt,
                createdAt: createdAt, updatedAt: updatedAt, tags: tags, captureLatitude: latitude,
                captureLongitude: longitude, trashedAt: trashedAt, title: title, body: body,
                unreadableProperties: unreadable)
        }

        mutating func object() throws(MarfaError) -> JSONObject {
            try nest()
            defer { depth -= 1 }
            let count = try count()
            var members: [JSONMember] = []
            members.reserveCapacity(min(count, (bytes.count - offset) / 5))
            for _ in 0..<count {
                let key = try text()
                members.append(JSONMember(key: key, value: try value()))
            }
            return JSONObject(members: members)
        }

        mutating func value() throws(MarfaError) -> JSONValue {
            switch try byte() {
            case 0: return .null
            case 1: return .bool(false)
            case 2: return .bool(true)
            case 3: return .integer(try int64())
            case 4: return .number(try double())
            case 5: return .string(try text())
            case 6:
                try nest()
                defer { depth -= 1 }
                let count = try count()
                var values: [JSONValue] = []
                values.reserveCapacity(min(count, bytes.count - offset))
                for _ in 0..<count { values.append(try value()) }
                return .array(values)
            case 7: return .object(try object())
            case let mark: throw failure("a value marked \(mark)")
            }
        }

        /// The core answers no properties nested deeper than its `MAX_JSON_DEPTH`, counting the properties object as
        /// the first level, and a recursive read of a value much deeper would overflow a secondary thread's stack.
        static let depthLimit = 64

        private mutating func nest() throws(MarfaError) {
            guard depth < Self.depthLimit else { throw failure("a value nested deeper than \(Self.depthLimit)") }
            depth += 1
        }
    }

    private struct Writer {
        var bytes = Data()

        mutating func byte(_ byte: UInt8) {
            bytes.append(byte)
        }

        mutating func count(_ count: Int) {
            withUnsafeBytes(of: UInt32(count).littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func int64(_ value: Int64) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func double(_ value: Double) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func text(_ text: String) {
            count(text.utf8.count)
            bytes.append(contentsOf: text.utf8)
        }

        mutating func optional<T>(_ value: T?, _ write: (inout Writer, T) -> Void) {
            guard let value else { return byte(0) }
            byte(1)
            write(&self, value)
        }

        mutating func item(_ item: Item) {
            text(item.id)
            text(item.type)
            object(item.properties)
            let state: UInt8 =
                switch item.state {
                case .active: 0
                case .archived: 1
                case .trashed: 2
                case .revoked: 3
                }
            let tier: UInt8 =
                switch item.tier {
                case nil: 0
                case .library: 1
                case .feed: 2
                }
            byte(state)
            byte(tier)
            int64(item.version)
            int64(item.schemaVersion)
            text(item.source)
            optional(item.sourceId) { $0.text($1) }
            text(item.occurredAt)
            text(item.createdAt)
            text(item.updatedAt)
            count(item.tags.count)
            for tag in item.tags { text(tag) }
            optional(item.captureLatitude) { $0.double($1) }
            optional(item.captureLongitude) { $0.double($1) }
            optional(item.trashedAt) { $0.text($1) }
            optional(item.title) { $0.text($1) }
            optional(item.body) { $0.text($1) }
            optional(item.unreadableProperties) { $0.text($1) }
        }

        mutating func object(_ object: JSONObject) {
            count(object.members.count)
            for member in object.members {
                text(member.key)
                value(member.value)
            }
        }

        mutating func value(_ value: JSONValue) {
            switch value {
            case .null: byte(0)
            case .bool(let flag): byte(flag ? 2 : 1)
            case .integer(let integer):
                byte(3)
                int64(integer)
            case .number(let number):
                byte(4)
                double(number)
            case .string(let string):
                byte(5)
                text(string)
            case .array(let values):
                byte(6)
                count(values.count)
                for element in values { self.value(element) }
            case .object(let object):
                byte(7)
                self.object(object)
            }
        }
    }
}
