import Testing
import Foundation
@testable import MarfaSDK

@Suite("JSONValue")
struct JSONValueTests {

    @Test("Encodes and decodes all value types")
    func roundTrip() throws {
        let value: JSONValue = .dictionary([
            "name": .string("test"),
            "count": .int(42),
            "ratio": .double(3.14),
            "active": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "empty": .null,
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == value)
    }

    @Test("String value accessor")
    func stringAccessor() {
        let v: JSONValue = .string("hello")
        #expect(v.stringValue == "hello")
        #expect(v.intValue == nil)
    }

    @Test("Int value accessor")
    func intAccessor() {
        let v: JSONValue = .int(42)
        #expect(v.intValue == 42)
        #expect(v.doubleValue == 42.0)
        #expect(v.stringValue == nil)
    }

    @Test("Bool value accessor")
    func boolAccessor() {
        let v: JSONValue = .bool(true)
        #expect(v.boolValue == true)
    }

    @Test("Null check")
    func nullCheck() {
        #expect(JSONValue.null.isNull == true)
        #expect(JSONValue.string("x").isNull == false)
    }

    @Test("Converts to [String: Any] and back")
    func anyConversion() {
        let original: [String: JSONValue] = [
            "title": .string("Test"),
            "count": .int(5),
        ]

        let anyDict = JSONValue.toDictionary(original)
        #expect(anyDict["title"] as? String == "Test")
        #expect(anyDict["count"] as? Int == 5)

        let restored = JSONValue.fromDictionary(anyDict)
        #expect(restored["title"] == .string("Test"))
        #expect(restored["count"] == .int(5))
    }

    @Test("Literal initialization")
    func literals() {
        let s: JSONValue = "hello"
        let i: JSONValue = 42
        let d: JSONValue = 3.14
        let b: JSONValue = true
        let n: JSONValue = nil

        #expect(s == .string("hello"))
        #expect(i == .int(42))
        #expect(d == .double(3.14))
        #expect(b == .bool(true))
        #expect(n == .null)
    }

    @Test("Dictionary literal initialization")
    func dictionaryLiteral() {
        let v: JSONValue = ["key": "value"]
        #expect(v.dictionaryValue?["key"] == .string("value"))
    }

    @Test("Array literal initialization")
    func arrayLiteral() {
        let v: JSONValue = [1, 2, 3]
        #expect(v.arrayValue?.count == 3)
    }
}
