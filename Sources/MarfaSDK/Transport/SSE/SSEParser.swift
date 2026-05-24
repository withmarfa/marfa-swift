import Foundation

/// Stateful parser for the Server-Sent Events text format.
///
/// Follows the WHATWG HTML spec §9.2.6 (event stream parsing):
/// - Lines starting with `:` are comments and ignored.
/// - `event:`, `data:`, `id:`, `retry:` fields accumulate until a blank line
///   dispatches an event.
/// - A single optional space after the colon is stripped.
/// - `data:` lines are joined with `\n`.
/// - `id:` persists as "last-event-id" state across subsequent events.
/// - Blocks with empty `data` do not dispatch an event (spec-conformant),
///   but `id:` and `retry:` side effects still apply.
/// - `retry:` attaches to the next event that fires.
///
/// The parser does not own byte iteration — that's the caller's job. Feed
/// lines one at a time via `consume(line:)` and yield any returned event.
struct SSEParser {

    // Per-block buffers
    private var eventType: String?
    private var data: [String] = []
    private var pendingRetry: TimeInterval?

    // Sticky across events
    private var lastEventID: String?

    init() {}

    /// Feeds the next line from the stream to the parser. Returns a fully-
    /// parsed `SSEEvent` when a blank line completes a block with data;
    /// returns `nil` otherwise.
    mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil
        }

        let field: String
        let value: String
        if let colonIndex = line.firstIndex(of: ":") {
            field = String(line[..<colonIndex])
            var start = line.index(after: colonIndex)
            if start < line.endIndex, line[start] == " " {
                start = line.index(after: start)
            }
            value = String(line[start...])
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventType = value.isEmpty ? nil : value
        case "data":
            data.append(value)
        case "id":
            // Per spec, an id containing a NUL character is ignored.
            if !value.contains("\0") {
                lastEventID = value
            }
        case "retry":
            if let ms = Int(value) {
                pendingRetry = TimeInterval(ms) / 1000.0
            }
        default:
            break
        }

        return nil
    }

    /// The stream's last-seen `id:` value. Consumers persist this and pass
    /// it back on reconnect via `Last-Event-ID`.
    var currentLastEventID: String? { lastEventID }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = nil
            data = []
            pendingRetry = nil
        }
        guard !data.isEmpty else { return nil }

        return SSEEvent(
            id: lastEventID,
            event: eventType,
            data: data.joined(separator: "\n"),
            retry: pendingRetry
        )
    }
}
