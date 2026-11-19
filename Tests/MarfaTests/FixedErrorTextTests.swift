import Testing

@testable import Marfa

/// The text an app's own error reporting may carry for a ``MarfaError``.
@Suite struct FixedErrorTextTests {
    @Test func aServerCodeIsKeptOnlyWhenItHasTheShapeOfOne() {
        let shaped = MarfaError.server(status: 500, code: "internal_error", message: "", details: nil, server: nil)
        #expect(shaped.fixedText.code == "internal_error")
        for code in ["Note abc 123", "01a1648c-0824", "", String(repeating: "a", count: 49), "/Users/x"] {
            let text = MarfaError.validation(code: code, message: "", details: nil, server: nil).fixedText
            #expect(text.code == "validation", "\(code)")
        }
        #expect(MarfaError.closed(message: "/Users/x").fixedText.code == "closed")
    }

    @Test func aCodeIsLowercaseLettersAndUnderscoresUpToFortyEightCharacters() {
        #expect(FixedErrorText.isCode(String(repeating: "a", count: 48)))
        #expect(FixedErrorText.isCode("a_b"))
        #expect(!FixedErrorText.isCode(String(repeating: "a", count: 49)))
        #expect(!FixedErrorText.isCode("A"))
        #expect(!FixedErrorText.isCode("a1"))
        #expect(!FixedErrorText.isCode("a b"))
    }

    @Test func theTextCarriesNothingTheErrorHolds() {
        let error = MarfaError.closed(message: "/Users/x/diary.md")
        #expect(!error.fixedText.sentence.contains("diary"))
        #expect(!error.fixedText.type.contains("Users"))
    }
}
