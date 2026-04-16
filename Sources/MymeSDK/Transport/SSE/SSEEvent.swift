import Foundation

/// One server-sent event as delivered by `Transport.eventStream(...)`.
///
/// Fields mirror the WHATWG SSE specification:
/// - ``id`` — the most recent `id:` field seen on this stream (sticky across
///   events per spec). Stream consumers such as ``SyncEngine`` persist this
///   as a cursor and pass it back as `Last-Event-ID` on reconnection.
/// - ``event`` — the `event:` type, if any. Callers usually switch on this.
/// - ``data`` — the `data:` payload. Multi-line `data:` fields are joined
///   with `\n`.
/// - ``retry`` — the server's reconnect hint in seconds, if this block
///   carried a `retry:` field. Advisory; the SDK's reconnect policy owns
///   whether to honour it.
public struct SSEEvent: Sendable, Equatable {
    public let id: String?
    public let event: String?
    public let data: String
    public let retry: TimeInterval?

    public init(id: String? = nil, event: String? = nil, data: String, retry: TimeInterval? = nil) {
        self.id = id
        self.event = event
        self.data = data
        self.retry = retry
    }
}
