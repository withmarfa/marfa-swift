import Testing
import Foundation
@testable import MarfaSDK

/// Helper that feeds a full SSE text body (a String containing `\n`-delimited
/// lines) through the parser and collects every dispatched event.
private func collectEvents(_ body: String) -> [SSEEvent] {
    var parser = SSEParser()
    var events: [SSEEvent] = []
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if let event = parser.consume(line: line) {
            events.append(event)
        }
    }
    return events
}

@Suite("SSE parser")
struct SSEParserTests {

    @Test("Single data event with one field")
    func singleDataEvent() {
        let events = collectEvents("data: hello\n\n")
        #expect(events.count == 1)
        #expect(events[0].data == "hello")
        #expect(events[0].event == nil)
        #expect(events[0].id == nil)
        #expect(events[0].retry == nil)
    }

    @Test("Multi-line data is joined with newline")
    func multiLineData() {
        let events = collectEvents("data: line one\ndata: line two\n\n")
        #expect(events.count == 1)
        #expect(events[0].data == "line one\nline two")
    }

    @Test("Event + id + data in a single block")
    func allFields() {
        let events = collectEvents("event: item.updated\nid: evt-42\ndata: {\"id\":\"x\"}\n\n")
        #expect(events.count == 1)
        #expect(events[0].event == "item.updated")
        #expect(events[0].id == "evt-42")
        #expect(events[0].data == "{\"id\":\"x\"}")
    }

    @Test("Comment lines produce no event")
    func commentLineIgnored() {
        let events = collectEvents(":heartbeat\n\n")
        #expect(events.isEmpty)
    }

    @Test("Empty block (blank line only) produces nothing")
    func emptyBlock() {
        let events = collectEvents("\n")
        #expect(events.isEmpty)
    }

    @Test("retry: parses to seconds")
    func retryParses() {
        let events = collectEvents("retry: 5000\ndata: tick\n\n")
        #expect(events.count == 1)
        #expect(events[0].retry == 5.0)
    }

    @Test("retry-only block (no data) does not dispatch")
    func retryOnlyBlockNoData() {
        let events = collectEvents("retry: 5000\n\n")
        #expect(events.isEmpty)
    }

    @Test("id: persists across subsequent events")
    func idSticks() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        let body = "id: a\ndata: one\n\ndata: two\n\nid: b\ndata: three\n\n"
        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let event = parser.consume(line: line) {
                events.append(event)
            }
        }
        #expect(events.count == 3)
        #expect(events[0].id == "a")
        #expect(events[1].id == "a")  // sticky
        #expect(events[2].id == "b")
    }

    @Test("Blank id: resets lastEventID to empty string")
    func blankIdResets() {
        var parser = SSEParser()
        _ = parser.consume(line: "id: abc")
        _ = parser.consume(line: "data: one")
        _ = parser.consume(line: "")  // dispatches
        _ = parser.consume(line: "id:")  // empty value
        _ = parser.consume(line: "data: two")
        let event = parser.consume(line: "")
        #expect(event?.id == "")
    }

    @Test("Single space after colon is stripped")
    func spaceAfterColonStripped() {
        let events = collectEvents("data:  two spaces\n\n")
        // First space stripped; second preserved.
        #expect(events[0].data == " two spaces")
    }

    @Test("Field with no colon treats line as field name with empty value")
    func bareFieldName() {
        // "data" (no colon) → data field with empty string, joined with \n
        let events = collectEvents("data\ndata: body\n\n")
        #expect(events.count == 1)
        #expect(events[0].data == "\nbody")
    }

    @Test("Unknown field ignored")
    func unknownField() {
        let events = collectEvents("foo: bar\ndata: body\n\n")
        #expect(events.count == 1)
        #expect(events[0].data == "body")
    }

    @Test("Multiple events in one buffer")
    func multipleEventsSequence() {
        let events = collectEvents("data: one\n\ndata: two\n\ndata: three\n\n")
        #expect(events.count == 3)
        #expect(events.map(\.data) == ["one", "two", "three"])
    }

    @Test("Invalid retry value is ignored")
    func invalidRetryIgnored() {
        let events = collectEvents("retry: notanumber\ndata: body\n\n")
        #expect(events[0].retry == nil)
    }

    @Test("currentLastEventID exposes the sticky id state")
    func exposesLastEventID() {
        var parser = SSEParser()
        #expect(parser.currentLastEventID == nil)
        _ = parser.consume(line: "id: abc123")
        #expect(parser.currentLastEventID == "abc123")
    }
}
