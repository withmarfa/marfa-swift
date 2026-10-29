import Foundation

/// One POST, ready to send.
package struct TelemetryRequest: Sendable {
    package let url: URL
    package let headers: [String: String]
    package let body: Data
}

/// Sends a request once. It reports nothing back: a report that fails is lost, and the app is told nothing.
package protocol TelemetryTransport: Sendable {
    func send(_ request: TelemetryRequest) async
}

/// An ephemeral session with no cookies, cache or credentials, a short timeout, and no redirects, since a redirect
/// would carry the project token to another host.
struct URLSessionTransport: TelemetryTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: Refusal(), delegateQueue: nil)
    }

    func send(_ request: TelemetryRequest) async {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        _ = try? await session.data(for: urlRequest)
    }

    private final class Refusal: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }
}
