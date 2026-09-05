import Foundation
import MarfaSDK
import os

/// In-process `Transport` for unit tests. Records every call and returns
/// canned responses enqueued by the test.
///
/// Instances are `@unchecked Sendable` because the recorded-calls array
/// and the response queues are guarded by an `NSLock` used only around
/// synchronous critical sections. Tests typically drive a mock from a
/// single task, which makes full actor isolation unnecessary overhead.
///
/// ## Missing-response handling
///
/// When a request arrives with no response queued, the mock throws
/// ``MissingMockResponseError`` rather than calling `fatalError`. This
/// matters when SyncEngine tests leak background drains: the engine's
/// own retry / drop machinery treats the throw as a network-class failure
/// and unwinds, instead of crashing the entire test process. Tests that
/// genuinely require an enqueued response still detect the gap via their
/// own assertions (`#expect(transport.calls.count == ...)` etc.). The
/// throw also logs through `MarfaLogger("transport-mock")` so the gap is
/// visible in test transcripts.
public struct MissingMockResponseError: Error, CustomStringConvertible {
    public let method: String
    public let path: String
    public var description: String {
        "MockTransport: no response queued for \(method) \(path)"
    }
}

private let mockTransportLogger = Logger(subsystem: "sdk.marfa", category: "transport-mock")

public final class MockTransport: Transport, @unchecked Sendable {

    public struct Call: Sendable {
        public let method: HTTPMethod
        public let path: String
        public let body: Data?
        public let query: [(String, String)]?
        /// Populated only for `eventStream(...)` calls — the `Last-Event-ID`
        /// the SDK passed when opening the SSE stream. Lets tests assert
        /// cursor-resume behavior.
        public let lastEventID: String?
        /// The `Idempotency-Key` the SDK sent, if any. A queued write carries
        /// the same value on every attempt, so a test can assert that a retry
        /// really is the same request rather than a second one.
        public let idempotencyKey: String?

        public init(
            method: HTTPMethod,
            path: String,
            body: Data?,
            query: [(String, String)]?,
            lastEventID: String? = nil,
            idempotencyKey: String? = nil
        ) {
            self.method = method
            self.path = path
            self.body = body
            self.query = query
            self.lastEventID = lastEventID
            self.idempotencyKey = idempotencyKey
        }
    }

    private enum Dequeue<T> {
        case error(Error?)
        case value(T)
        case missing
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var responses: [Data] = []
    private var rawResponses: [(Data, HTTPURLResponse)] = []
    private var errors: [Error?] = []
    private var eventStreams: [[SSEEvent]] = []

    public init() {}

    /// All recorded calls in order.
    public var calls: [Call] {
        lock.withLock { _calls }
    }

    // MARK: - Configuration

    /// Queue a typed response for the next `request()` or `requestWithConflict()` call.
    public func enqueue<T: Encodable>(_ response: T) {
        let data = try! JSONEncoder().encode(response)
        lock.withLock { responses.append(data) }
    }

    /// Queue raw response bytes + status for the next `rawRequest()` call.
    public func enqueueRaw(data: Data, statusCode: Int = 200, headers: [String: String] = [:]) {
        let merged = headers.merging(["Content-Type": "application/json"]) { a, _ in a }
        let response = HTTPURLResponse(
            url: URL(string: "http://mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: merged
        )!
        lock.withLock { rawResponses.append((data, response)) }
    }

    /// Queue an error for the next call (any method).
    public func enqueueError(_ error: Error) {
        lock.withLock { errors.append(error) }
    }

    /// Queue a sequence of SSE events for the next `eventStream()` call.
    public func enqueueEvents(_ events: [SSEEvent]) {
        lock.withLock { eventStreams.append(events) }
    }

    // MARK: - Transport

    public func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        let bodyData = body.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }
        let outcome: Dequeue<Data> = lock.withLock {
            _calls.append(Call(method: method, path: path, body: bodyData, query: query))
            if !errors.isEmpty { return .error(errors.removeFirst()) }
            if responses.isEmpty { return .missing }
            return .value(responses.removeFirst())
        }
        switch outcome {
        case .error(let e):
            if let e { throw e }
            fatalError("MockTransport: nil error enqueued")
        case .missing:
            let err = MissingMockResponseError(method: method.rawValue, path: path)
            mockTransportLogger.error("\(err.description, privacy: .public)")
            throw err
        case .value(let data):
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    public func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?,
        idempotencyKey: String?
    ) async throws -> T {
        let bodyData = body.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }
        let outcome: Dequeue<Data> = lock.withLock {
            _calls.append(Call(
                method: method, path: path, body: bodyData, query: query,
                idempotencyKey: idempotencyKey
            ))
            if !errors.isEmpty { return .error(errors.removeFirst()) }
            if responses.isEmpty { return .missing }
            return .value(responses.removeFirst())
        }
        switch outcome {
        case .error(let e):
            if let e { throw e }
            fatalError("MockTransport: nil error enqueued")
        case .missing:
            let err = MissingMockResponseError(method: method.rawValue, path: path)
            mockTransportLogger.error("\(err.description, privacy: .public)")
            throw err
        case .value(let data):
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    public func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        let bodyData = body.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }
        let outcome: Dequeue<Data> = lock.withLock {
            _calls.append(Call(method: method, path: path, body: bodyData, query: query))
            if !errors.isEmpty { return .error(errors.removeFirst()) }
            if responses.isEmpty { return .missing }
            return .value(responses.removeFirst())
        }
        switch outcome {
        case .error(let e):
            if let e { throw e }
            fatalError("MockTransport: nil error enqueued")
        case .missing:
            let err = MissingMockResponseError(method: method.rawValue, path: path)
            mockTransportLogger.error("\(err.description, privacy: .public)")
            throw err
        case .value(let data):
            if let result = try? JSONDecoder().decode(T.self, from: data) {
                return .success(result)
            }
            if let conflict = try? JSONDecoder().decode(ConflictResponse.self, from: data) {
                return .conflict(conflict)
            }
            return .success(try JSONDecoder().decode(T.self, from: data))
        }
    }

    /// `rawUpload` parity — routes through the same queued `rawResponses`
    /// / `errors` machinery as ``rawRequest(method:path:body:contentType:query:)``,
    /// with the addition of synthetic progress ticks emitted before the
    /// response is returned. Ticks fire at 0 %, 50 %, 100 % of the body
    /// size, which is enough to exercise a consumer's progress observer
    /// (started → one or more progress events → completed) without any
    /// real network I/O.
    public func rawUpload(
        method: HTTPMethod,
        path: String,
        body: Data,
        contentType: String?,
        query: [(String, String)]?,
        onBytesSent: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let outcome: Dequeue<(Data, HTTPURLResponse)> = lock.withLock {
            _calls.append(Call(method: method, path: path, body: body, query: query))
            if !errors.isEmpty { return .error(errors.removeFirst()) }
            if rawResponses.isEmpty { return .missing }
            return .value(rawResponses.removeFirst())
        }

        switch outcome {
        case .error(let e):
            if let e { throw e }
            fatalError("MockTransport: nil error enqueued")
        case .missing:
            let err = MissingMockResponseError(method: method.rawValue, path: path)
            mockTransportLogger.error("raw \(err.description, privacy: .public)")
            throw err
        case .value(let response):
            // Synthetic progress: 0, halfway, complete. Keeps tests
            // deterministic while still exercising the observer path.
            let total = Int64(body.count)
            onBytesSent(0, total)
            if total > 0 {
                onBytesSent(total / 2, total)
                onBytesSent(total, total)
            }
            return response
        }
    }

    public func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        let outcome: Dequeue<(Data, HTTPURLResponse)> = lock.withLock {
            _calls.append(Call(method: method, path: path, body: body, query: query))
            if !errors.isEmpty { return .error(errors.removeFirst()) }
            if rawResponses.isEmpty { return .missing }
            return .value(rawResponses.removeFirst())
        }
        switch outcome {
        case .error(let e):
            if let e { throw e }
            fatalError("MockTransport: nil error enqueued")
        case .missing:
            let err = MissingMockResponseError(method: method.rawValue, path: path)
            mockTransportLogger.error("raw \(err.description, privacy: .public)")
            throw err
        case .value(let response):
            return response
        }
    }

    public func eventStream(
        path: String,
        query: [(String, String)]?,
        lastEventID: String?
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        enum EventOutcome {
            case error(Error?)
            case events([SSEEvent])
            case noneQueued
        }
        let outcome: EventOutcome = lock.withLock {
            _calls.append(Call(method: .get, path: path, body: nil, query: query, lastEventID: lastEventID))
            // Prefer a queued event sequence over a shared error. Tests that
            // want `eventStream` to throw can enqueue an error *without*
            // enqueueing events, in which case the error branch fires.
            if !eventStreams.isEmpty { return .events(eventStreams.removeFirst()) }
            if !errors.isEmpty { return .error(errors.removeFirst()) }
            return .noneQueued
        }
        return AsyncThrowingStream { continuation in
            switch outcome {
            case .error(let e):
                continuation.finish(throwing: e ?? CancellationError())
            case .events(let events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case .noneQueued:
                continuation.finish()
            }
        }
    }
}
