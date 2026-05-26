import Foundation
import MarfaSDK

/// Test fake for ``DeviceFlowHTTPClient``. Records every request and
/// returns scripted responses in FIFO order. Per-instance state — safe
/// for parallel tests.
///
/// ```swift
/// let http = FakeDeviceFlowHTTPClient()
/// http.enqueueOAuthError(code: "authorization_pending")
/// http.enqueueTokenResponse(accessToken: "abc")
/// // ... drive DeviceFlow with `http`, then assert against http.calls
/// ```
public final class FakeDeviceFlowHTTPClient: DeviceFlowHTTPClient, @unchecked Sendable {

    private enum QueuedResponse {
        case data(Data, HTTPURLResponse)
        case error(Error)
    }

    private let lock = NSLock()
    private var _calls: [URLRequest] = []
    private var responses: [QueuedResponse] = []

    public init() {}

    /// All recorded requests in order.
    public var calls: [URLRequest] {
        lock.withLock { _calls }
    }

    // MARK: - Scripting

    /// Queue a raw response (body + status). Default `Content-Type`
    /// is `application/json`.
    public func enqueue(
        data: Data,
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) {
        let response = HTTPURLResponse(
            url: URL(string: "http://fake")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        lock.withLock { responses.append(.data(data, response)) }
    }

    /// Queue a JSON-encoded response body.
    public func enqueueJSON<T: Encodable>(_ value: T, status: Int = 200) throws {
        let data = try JSONEncoder().encode(value)
        enqueue(data: data, status: status)
    }

    /// Queue an RFC 6749 §5.2 OAuth error envelope. Status defaults to
    /// 400 — RFC 8628 polling errors (`authorization_pending`,
    /// `slow_down`, `access_denied`, `expired_token`) all use 400.
    public func enqueueOAuthError(
        code: String,
        description: String? = nil,
        status: Int = 400
    ) {
        var body: [String: String] = ["error": code]
        if let description { body["error_description"] = description }
        let data = try! JSONSerialization.data(withJSONObject: body)
        enqueue(data: data, status: status)
    }

    /// Queue a fully-formed token bundle (RFC 6749 §5.1 wire shape).
    public func enqueueTokenResponse(
        accessToken: String = "test-access-token",
        tokenType: String = "bearer",
        refreshToken: String? = "test-refresh-token",
        expiresInSeconds: Int? = 3600,
        scope: String = "core.note:read"
    ) {
        var body: [String: Any] = [
            "access_token": accessToken,
            "token_type": tokenType,
            "scope": scope,
        ]
        if let refreshToken { body["refresh_token"] = refreshToken }
        if let expiresInSeconds { body["expires_in"] = expiresInSeconds }
        let data = try! JSONSerialization.data(withJSONObject: body)
        enqueue(data: data, status: 200)
    }

    /// Queue a device-authorization response (the start endpoint's success
    /// payload, RFC 8628 §3.2).
    public func enqueueDeviceCodeResponse(
        deviceCode: String = "test-device-code",
        userCode: String = "ABCD-EFGH",
        verificationURI: String = "https://example.test/device",
        verificationURIComplete: String? = nil,
        expiresInSeconds: Int = 1800,
        interval: Int? = 5
    ) {
        var body: [String: Any] = [
            "device_code": deviceCode,
            "user_code": userCode,
            "verification_uri": verificationURI,
            "expires_in": expiresInSeconds,
        ]
        if let verificationURIComplete {
            body["verification_uri_complete"] = verificationURIComplete
        }
        if let interval {
            body["interval"] = interval
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        enqueue(data: data, status: 200)
    }

    /// Queue an error to be thrown by the next call.
    public func enqueueError(_ error: Error) {
        lock.withLock { responses.append(.error(error)) }
    }

    // MARK: - DeviceFlowHTTPClient

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        enum Outcome {
            case data(Data, HTTPURLResponse)
            case error(Error)
            case missing(method: String, url: String)
        }
        let outcome: Outcome = lock.withLock {
            _calls.append(request)
            guard !responses.isEmpty else {
                return .missing(
                    method: request.httpMethod ?? "?",
                    url: request.url?.absoluteString ?? "?"
                )
            }
            switch responses.removeFirst() {
            case .data(let d, let r): return .data(d, r)
            case .error(let e): return .error(e)
            }
        }
        switch outcome {
        case .data(let data, let response):
            return (data, response)
        case .error(let error):
            throw error
        case .missing(let method, let url):
            throw FakeDeviceFlowHTTPClientError.noResponseQueued(method: method, url: url)
        }
    }
}

/// Failures from ``FakeDeviceFlowHTTPClient``. Thrown when a request
/// arrives with no scripted response queued.
public enum FakeDeviceFlowHTTPClientError: Error, CustomStringConvertible {
    case noResponseQueued(method: String, url: String)

    public var description: String {
        switch self {
        case let .noResponseQueued(method, url):
            return "FakeDeviceFlowHTTPClient: no response queued for \(method) \(url)"
        }
    }
}
