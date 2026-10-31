import Testing

@testable import Marfa

@Suite struct SearchExcerpts {
    private func runs(_ html: String) -> [SearchExcerpt.Run] { SearchExcerpt(html: html).runs }

    private func run(_ text: String, _ isMatch: Bool = false) -> SearchExcerpt.Run {
        SearchExcerpt.Run(text: text, isMatch: isMatch)
    }

    @Test func textAroundAMatchIsThreeRuns() {
        #expect(runs("a <mark>zebra</mark> herd") == [run("a "), run("zebra", true), run(" herd")])
    }

    @Test func aMatchAtEitherEndLeavesNoEmptyRun() {
        #expect(runs("<mark>Zebra</mark> crossing") == [run("Zebra", true), run(" crossing")])
        #expect(runs("the <mark>zebra</mark>") == [run("the "), run("zebra", true)])
        #expect(runs("<mark>zebra</mark>") == [run("zebra", true)])
    }

    @Test func neighboringMatchesAreOneRunOnlyWhereNothingSitsBetween() {
        #expect(runs("<mark>ran</mark><mark>five</mark>") == [run("ranfive", true)])
        #expect(
            runs("<mark>ran</mark> <mark>five</mark>") == [run("ran", true), run(" "), run("five", true)])
    }

    @Test func theFiveEscapesReadAsTheirCharacters() {
        let html = "he said &quot;quiet&quot; &amp; &lt;b&gt;it&#39;s&lt;/b&gt;"
        #expect(runs(html) == [run("he said \"quiet\" & <b>it's</b>")])
        #expect(runs("&lt;mark&gt;<mark>&amp;</mark>") == [run("<mark>"), run("&", true)], "an escaped tag is text")
    }

    @Test func numericReferencesReadAndAnUnknownOneStays() {
        #expect(runs("&#x41;&#66;") == [run("AB")])
        #expect(runs("fish &chips; &amp") == [run("fish &chips; &amp")])
        #expect(runs("a & b") == [run("a & b")])
    }

    @Test func theCutIsAPlainRun() {
        #expect(runs("...the <mark>river</mark> bank...") == [run("...the "), run("river", true), run(" bank...")])
    }

    @Test func anExcerptWithNoMarkIsOneRunOfNoMatch() {
        #expect(runs("nothing marked") == [run("nothing marked")])
    }

    @Test func whitespaceIsKept() {
        #expect(runs("line one\nline  <mark>two</mark>") == [run("line one\nline  "), run("two", true)])
    }

    @Test func emptyHoldsNoRun() {
        #expect(runs("").isEmpty)
        #expect(runs("<mark></mark>").isEmpty)
    }

    @Test func aStrayOrUnknownTagIsDroppedAndAnUnpairedCloseMarksNothing() {
        #expect(runs("a <b>bold</b> </mark>word") == [run("a bold word")])
        #expect(runs("<mark>open and never closed") == [run("open and never closed", true)])
    }

    @Test func theTextIsTheExcerptWithoutItsMarks() {
        #expect(SearchExcerpt(html: "a <mark>zebra</mark> &amp; more").text == "a zebra & more")
    }

    @Test func aHitReadsItsOwnSnippet() {
        let item = Item(
            id: "i", type: "note", properties: [:], state: .active, tier: nil, version: 1, schemaVersion: 1,
            source: "app", sourceId: nil, occurredAt: "2026-10-27T14:00:00.000Z",
            createdAt: "2026-10-27T14:00:00.000Z", updatedAt: "2026-10-27T14:00:00.000Z", tags: [])
        let hit = SearchHit(item: item, score: 1, snippet: "a <mark>zebra</mark>")
        #expect(hit.excerpt.runs == [run("a "), run("zebra", true)])
    }
}
