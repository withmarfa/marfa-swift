import Foundation
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct JSONObjectTests {
    @Suite struct Objects {
        @Test func aLiteralKeepsItsOrder() {
            let object: JSONObject = ["z": 1, "a": "two", "m": [3]]
            #expect(object.keys == ["z", "a", "m"])
            #expect(object.values == [1, "two", [3]])
            #expect(object.map(\.key) == ["z", "a", "m"])
            #expect(object[1].key == "a")
            #expect(object.count == 3)
            #expect(!object.isEmpty)
            #expect(JSONObject().isEmpty)
        }

        @Test func aRepeatedKeyTakesItsLastValueAtItsFirstPosition() {
            let literal = JSONObject(dictionaryLiteral: ("a", 1), ("b", 2), ("a", 3))
            #expect(literal.keys == ["a", "b"])
            #expect(literal["a"] == 3)
            let paired = JSONObject([("a", 1), ("b", 2), ("a", 3)])
            #expect(paired == literal)
            let value = JSONValue(dictionaryLiteral: ("a", 1), ("b", 2), ("a", 3))
            #expect(value == .object(literal))
        }

        @Test func settingReplacesInPlaceAppendsNewAndRemovesNil() {
            var object: JSONObject = ["a": 1, "b": 2, "c": 3]
            object["b"] = "two"
            #expect(object.keys == ["a", "b", "c"])
            #expect(object["b"] == "two")
            object["d"] = 4
            #expect(object.keys == ["a", "b", "c", "d"])
            object["a"] = nil
            #expect(object.keys == ["b", "c", "d"])
            #expect(object["a"] == nil)
            #expect(object.removeValue(forKey: "c") == 3)
            #expect(object.removeValue(forKey: "c") == nil)
            object["d"] = 5
            object["e"] = 6
            #expect(object.keys == ["b", "d", "e"])
            #expect(object.values == ["two", 5, 6])
        }

        @Test func pairsMakeTheSameObjectAgain() {
            let object: JSONObject = ["z": 1, "a": 2]
            #expect(JSONObject(object.map { ($0.key, $0.value) }) == object)
        }

        @Test func equalityAndHashingAreOrderSensitive() {
            let forward: JSONObject = ["a": 1, "b": 2]
            let backward: JSONObject = ["b": 2, "a": 1]
            #expect(forward != backward)
            #expect(JSONValue.object(forward) != .object(backward))
            #expect(Set([forward, backward]).count == 2)
            let again: JSONObject = ["a": 1, "b": 2]
            #expect(forward == again)
            #expect(forward.hashValue == again.hashValue)
        }

        @Test func encodingHandsTheKeysOverInOrder() throws {
            let object: JSONObject = ["z": 1, "a": 2, "m": 3, "b": 4]
            let recorder = KeyRecorder()
            try object.encode(to: recorder)
            #expect(recorder.keys.keys == ["z", "a", "m", "b"])
        }

        @Test func decodingSortsTheKeysADecoderGives() throws {
            let text = Data(#"{"b":1,"c":{"z":1,"y":2},"a":2}"#.utf8)
            let decoded = try JSONDecoder().decode(JSONObject.self, from: text)
            #expect(decoded.keys == ["a", "b", "c"])
            #expect(decoded["c"]?.object?.keys == ["y", "z"])
        }

        @Test func aValueOpensAsAnObjectOrAnArray() {
            let value: JSONValue = ["list": [1, 2], "inner": ["k": "v"]]
            #expect(value.object?.keys == ["list", "inner"])
            #expect(value.object?["list"]?.array == [1, 2])
            #expect(value.object?["inner"]?.object == ["k": "v"])
            #expect(value.array == nil)
            #expect(JSONValue.string("s").object == nil)
        }

        @Test func aValueDescribesItselfAsJSON() {
            let object: JSONObject = ["b": [1, 0.5], "a": "x"]
            #expect("\(object)" == #"{"b":[1,0.5],"a":"x"}"#)
            #expect("\(JSONValue.number(.nan))" == "nan")
        }
    }

    @Suite struct Reading {
        @Test func canonicalTextReadsAndWritesBackTheSame() throws {
            let text =
                #"{"z":{"y":[1,-2,0.5,"s",true,false,null,{"b":{},"a":[]}],"x":"é😀\n"},"a":[[[]]],"m":-1.5e-07}"#
            #expect(try JSONValue(json: text).json() == text)
            #expect(try JSONObject(json: text).json() == text)
        }

        @Test func aWrittenValueReadsBackEqual() throws {
            let value: JSONValue = [
                "title": "A \"note\"\twith\u{1}control", "count": 3, "ratio": 0.25, "done": false, "none": nil,
                "tags": ["a", "b"], "nested": ["z": ["deep": [1, ["k": -0.125]]], "a": [:], "e": []],
            ]
            #expect(try JSONValue(json: value.json()) == value)
        }

        @Test func keyOrderIsKeptAtEveryDepth() throws {
            let read = try JSONObject(json: #" {"b": {"d": 1, "c": 2}, "a": [{"f": 1, "e": {"h": 1, "g": 2}}]} "#)
            #expect(read.keys == ["b", "a"])
            #expect(read["b"]?.object?.keys == ["d", "c"])
            let inner = read["a"]?.array?.first?.object
            #expect(inner?.keys == ["f", "e"])
            #expect(inner?["e"]?.object?.keys == ["h", "g"])
        }

        @Test func whitespaceAroundTokensIsAllowed() throws {
            let read = try JSONValue(json: " \t\n\r{ \"a\" : [ 1 , 2 ] , \"b\" :{ } }\r\n")
            #expect(read == ["a": [1, 2], "b": [:]])
        }

        static let numbers: [(String, JSONValue)] = [
            ("0", .integer(0)),
            ("-0", .integer(0)),
            ("-0.0", .integer(0)),
            ("0e5", .integer(0)),
            ("9223372036854775807", .integer(.max)),
            ("-9223372036854775808", .integer(.min)),
            ("9223372036854775808", .number(0x1p63)),
            ("-9223372036854775809", .number(-0x1p63)),
            ("1.0", .integer(1)),
            ("1e2", .integer(100)),
            ("1E+2", .integer(100)),
            ("100e-2", .integer(1)),
            ("1.5e1", .integer(15)),
            ("0.0001e4", .integer(1)),
            ("9007199254740993.0", .integer(9_007_199_254_740_993)),
            ("9223372036854775807.0", .integer(.max)),
            ("-9223372036854775808e0", .integer(.min)),
            ("9.223372036854775808e18", .number(9.223372036854775808e18)),
            ("0.1", .number(0.1)),
            ("1e-7", .number(1e-7)),
            ("-1.5", .number(-1.5)),
            ("1e300", .number(1e300)),
        ]

        @Test(arguments: numbers)
        func aNumberReadsExactWhereInt64HoldsIt(text: String, expected: JSONValue) throws {
            let read = try JSONValue(json: text)
            #expect(read == expected)
            if case .number(let value) = expected {
                #expect(read.number?.bitPattern == value.bitPattern)
            }
        }

        static let badNumbers = [
            "1e400", "-1e400", "1e99999999999999999999", "01", "-01", "00", ".5", "5.", "-", "+1", "1e", "1e+",
            "1.e5", "0x10", "NaN", "Infinity", "-Infinity", "1_000", "--1",
        ]

        @Test(arguments: badNumbers)
        func aNumberJSONDoesNotAllowIsRefused(text: String) {
            expectRefused(text)
            expectRefused("[\(text)]")
        }

        @Test func eachEscapeReads() throws {
            #expect(try JSONValue(json: #""\"\\\/\b\f\n\r\t""#) == .string("\"\\/\u{8}\u{C}\n\r\t"))
            #expect(try JSONValue(json: #""éé""#) == "éé")
            #expect(try JSONValue(json: #""a😀b""#) == "a😀b")
            #expect(try JSONValue(json: #""\u0000""#) == "\u{0}")
            #expect(try JSONValue(json: "\"é😀\"") == "é😀")
        }

        static let badStrings = [
            #""\ud83d""#, #""\ud83dx""#, #""\ude00""#, #""\ude00\ud83d""#, #""\ud83dA""#, #""\ud83d\n""#,
            #""\x41""#, #""\u12""#, #""\u12G4""#, #""\'""#, "\"a\u{1}b\"", "\"a\tb\"", "\"a\nb\"", "\"abc",
            #""\"#,
        ]

        @Test(arguments: badStrings)
        func aStringJSONDoesNotAllowIsRefused(text: String) {
            expectRefused(text)
        }

        @Test func aKeyRepeatedInOneObjectIsRefused() throws {
            expectRefused(#"{"a":1,"a":2}"#, naming: "duplicate key at byte offset 7")
            expectRefused(#"{"x":{"a":1,"b":2,"a":3}}"#, naming: "duplicate key")
            #expect(try JSONValue(json: #"{"a":{"a":1},"b":[{"a":1},{"a":2}]}"#).object?.count == 2)
        }

        @Test func nestingIsReadUpToTheLimit() throws {
            let limit = JSONValue.nestingLimit
            #expect(limit == 512)
            func arrays(_ depth: Int) -> String {
                String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
            }
            func objects(_ depth: Int) -> String {
                String(repeating: #"{"a":"#, count: depth - 1) + "{}" + String(repeating: "}", count: depth - 1)
            }
            #expect(try JSONValue(json: arrays(limit)).json() == arrays(limit))
            #expect(try JSONValue(json: objects(limit)).json() == objects(limit))
            expectRefused(arrays(limit + 1), naming: "nesting deeper than 512")
            expectRefused(objects(limit + 1), naming: "nesting deeper than 512")
            expectRefused(String(repeating: "[", count: 100_000), naming: "nesting deeper than 512")
            expectRefused(String(repeating: #"{"a":"#, count: 100_000), naming: "nesting deeper than 512")
        }

        static let badDocuments = [
            "", " ", "1 2", "{} x", "[1,]", #"{"a":1,}"#, "'a'", "{'a':1}", "// c\n1", "/* c */1", "{a:1}",
            "[1 2]", #"{"a" 1}"#, #"{"a":}"#, #"{"a"}"#, "[", "{", "[1", #"{"a":1"#, "tru", "nul", "True",
            "\u{FEFF}1", "[1]\u{0}", "\u{C}1", "[,1]", "{,}", "[1]]",
        ]

        @Test(arguments: badDocuments)
        func textThatIsNotOneJSONValueIsRefused(text: String) {
            expectRefused(text)
        }

        static let badBytes: [[UInt8]] = [
            [0x22, 0xFF, 0x22],
            [0x22, 0xC3, 0x22],
            [0x22, 0xC0, 0x80, 0x22],
            [0x22, 0xED, 0xA0, 0x80, 0x22],
            [0x22, 0xF4, 0x90, 0x80, 0x80, 0x22],
            [0xFF],
        ]

        @Test(arguments: badBytes)
        func invalidUTF8IsRefused(bytes: [UInt8]) {
            #expect {
                try JSONReader.value(bytes: bytes)
            } throws: { error in
                if case MarfaError.decoding = error { true } else { false }
            }
        }

        @Test func validUTF8BytesRead() throws {
            #expect(try JSONReader.value(bytes: [0x22, 0xC3, 0xA9, 0x22]) == "é")
        }

        @Test(arguments: ["[1]", "1", #""x""#, "null", "", "  [", "true"])
        func anObjectIsReadOnlyFromAnObject(text: String) {
            #expect {
                try JSONObject(json: text)
            } throws: { error in
                guard case MarfaError.decoding(let message) = error else { return false }
                return message.contains("byte offset")
            }
        }
    }

    @Suite struct Writing {
        @Test func eachSpecialCharacterIsEscapedMinimally() throws {
            let text: JSONValue = "\"\\/\u{8}\u{C}\n\r\t\u{0}\u{1F}é😀\u{7F}\u{2028}"
            let expected = #""\"\\/\b\f\n\r\t\u0000\u001fé😀"# + "\u{7F}\u{2028}\""
            #expect(try text.json() == expected)
            #expect(try JSONValue(json: expected) == text)
        }

        @Test func anObjectIsWrittenCompactInOrder() throws {
            let object: JSONObject = ["b": [1, 2], "a": [:], "c": ["y": nil, "x": true]]
            #expect(try object.json() == #"{"b":[1,2],"a":{},"c":{"y":null,"x":true}}"#)
        }

        @Test func integersAreWrittenAsTheirDigits() throws {
            #expect(try JSONValue.integer(.min).json() == "-9223372036854775808")
            #expect(try JSONValue.integer(.max).json() == "9223372036854775807")
        }

        @Test(arguments: [
            0.1, 0.25, -1.5, 1e-5, 1e-7, 5e20, 1.2345678901234568e20, 5e-324, 1.7976931348623157e308, -2.5e-300,
        ])
        func aDoubleIsWrittenShortestAndReadsBack(value: Double) throws {
            let text = try JSONValue.number(value).json()
            #expect(text == value.description)
            #expect(try JSONValue(json: text) == .number(value))
        }

        @Test(arguments: [Double.nan, .infinity, -.infinity])
        func aNumberThatIsNotFiniteIsRefusedAsInvalid(value: Double) {
            let nested: JSONObject = ["a": [1, .number(value)]]
            for (written, path) in [(JSONValue.number(value), "the value"), (.object(nested), "a.1")] {
                #expect {
                    try written.json()
                } throws: { error in
                    guard case MarfaError.invalid(let message) = error else { return false }
                    return message.hasPrefix("\(path) cannot be written as JSON")
                }
            }
        }
    }

    @Test func aLargeObjectReadsAndWritesQuickly() throws {
        var object = JSONObject()
        for index in 0..<400 {
            object["entry \(index)"] = [
                "title": .string("A title with \"quotes\", é, a\ttab and a line\nbreak, number \(index)"),
                "body": .string(String(repeating: "Some body text. ", count: 6)),
                "n": .integer(Int64(index) * 1_000_003),
                "r": .number(Double(index) + 0.125),
                "tags": ["alpha", "beta", .string("tag \(index)")],
                "nested": ["x": [1, 2, ["y": nil, "z": false]], "w": -0.5],
            ]
        }
        let clock = ContinuousClock()
        var text = ""
        let writing = try clock.measure { text = try object.json() }
        #expect(text.utf8.count > 100_000)
        var read = JSONObject()
        let reading = try clock.measure { read = try JSONObject(json: text) }
        #expect(read == object)
        #expect(writing < .milliseconds(500), "writing took \(writing)")
        #expect(reading < .milliseconds(500), "reading took \(reading)")
    }
}

private func expectRefused(
    _ text: String, naming problem: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(sourceLocation: sourceLocation) {
        try JSONValue(json: text)
    } throws: { error in
        guard case MarfaError.decoding(let message) = error else { return false }
        return message.contains("byte offset") && (problem.map { message.contains($0) } ?? true)
    }
}

/// The keys an encodable hands its keyed container, in the order it hands them.
private final class KeyRecorder: Encoder {
    final class Keys {
        var keys: [String] = []
    }

    let keys = Keys()
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(Container(keys: keys))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        preconditionFailure("only a keyed container is recorded")
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        preconditionFailure("only a keyed container is recorded")
    }

    private struct Container<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let keys: Keys
        var codingPath: [any CodingKey] { [] }

        mutating func encodeNil(forKey key: Key) { keys.keys.append(key.stringValue) }

        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) { keys.keys.append(key.stringValue) }

        mutating func nestedContainer<NestedKey: CodingKey>(
            keyedBy keyType: NestedKey.Type, forKey key: Key
        ) -> KeyedEncodingContainer<NestedKey> {
            preconditionFailure("only the top level is recorded")
        }

        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
            preconditionFailure("only the top level is recorded")
        }

        mutating func superEncoder() -> any Encoder {
            preconditionFailure("only the top level is recorded")
        }

        mutating func superEncoder(forKey key: Key) -> any Encoder {
            preconditionFailure("only the top level is recorded")
        }
    }
}
