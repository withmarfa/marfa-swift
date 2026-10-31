import Foundation
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct LinkPartsOffline {
    /// The text a range covers, counted as a text view counts.
    private func slice(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    @Test func eachLinkInATextCarriesItsPartsInOrderRepeatsIncluded() {
        let text = "See [[Plan#Goals|the goals]], [[Plan]] and [[Plan]]."
        let found = linkParts(in: text)
        #expect(found.map(\.target) == ["Plan#Goals|the goals", "Plan", "Plan"])
        #expect(found.map { slice(text, $0.range) } == ["[[Plan#Goals|the goals]]", "[[Plan]]", "[[Plan]]"])
        let first = found[0]
        #expect(first.name.text == "Plan" && slice(text, first.name.range) == "Plan")
        #expect(first.heading.map { slice(text, $0.range) } == "Goals")
        #expect(first.alias.map { slice(text, $0.range) } == "the goals")
        #expect(found[1].heading == nil && found[1].alias == nil)
    }

    @Test func aLinkAfterAnEmojiIsPlacedInUTF16UnitsAndNotCharacters() throws {
        let text = "👩‍👩‍👧 and 🎉 [[Café]]"
        let link = try #require(linkParts(in: text).first)
        #expect(link.range.location == (text as NSString).range(of: "[[").location)
        #expect(link.range.location != text.distance(from: text.startIndex, to: try #require(text.firstRange(of: "[["))?.lowerBound ?? text.startIndex))
        #expect(slice(text, link.range) == "[[Café]]")
        #expect(slice(text, link.name.range) == "Café")
        let range = try #require(Range(link.range, in: text))
        #expect(text[range] == "[[Café]]")
    }

    @Test func aHeadingOnlyLinkAndATextWithNoLinkAreRead() {
        #expect(linkParts(in: "nothing here").isEmpty)
        let found = linkParts(in: "[[#Goals]]")
        #expect(found.count == 1)
        #expect(found[0].heading?.text == "Goals")
    }

    @Test func aBackslashIsPartOfTheText() {
        let found = linkParts(in: #"[[A\]]"#)
        #expect(found.first?.target == #"A\"#)
    }

    @Test func candidatesSayWhatEachTargetCouldName() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        func note(_ title: String) async throws -> String {
            try #require(try await copy.items.create(Draft(type: "core.note", properties: ["title": .string(title)])).itemId)
        }
        let plan = try await note("Plan")
        let first = try await note("Twin")
        let second = try await note("Twin")
        let found = try await copy.items.linkCandidates(of: ["Plan", "Twin", "Nothing", plan])
        #expect(found.map(\.state) == [.unresolved, .ambiguous, .unresolved, .bound])
        #expect(found[0].item == nil && found[0].candidates == [plan], "a name binds only in an item's body")
        #expect(found[1].item == nil && Set(found[1].candidates) == [first, second])
        #expect(found[2].candidates.isEmpty && found[2].target == "Nothing")
        #expect(found[3].item == plan)
        await copy.close()
    }

    @Test func candidatesReadInAnItemAndRefuseOneTheCopyDoesNotHold() async throws {
        let copy = try await WorkingCopy.open(store: temporaryStore())
        let other = try #require(
            try await copy.items.create(Draft(type: "core.note", properties: ["title": "Other"])).itemId)
        let host = try #require(
            try await copy.items.create(
                Draft(type: "core.note", properties: ["title": "Host", "body": .string("See [[\(other)]] and [[Nothing]].")])
            ).itemId)
        let found = try await copy.items.linkCandidates(of: [other, "Nothing"], in: host)
        #expect(found.map(\.target) == [other, "Nothing"])
        #expect(found.map(\.state) == [.bound, .unresolved])
        #expect(found[0].item == other && found[0].candidates == [other])
        await #expect {
            try await copy.items.linkCandidates(of: ["Other"], in: "absent")
        } throws: { error in
            if case MarfaError.notFound? = error as? MarfaError { true } else { false }
        }
        await copy.close()
    }
}
