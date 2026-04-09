import Foundation
@testable import MymeSDK

/// Mock transport for unit tests. Records calls and returns pre-configured responses.
final class MockTransport: Transport, @unchecked Sendable {

    struct Call: Sendable {
        let method: HTTPMethod
        let path: String
        let body: Data?
        let query: [(String, String)]?
    }

    private(set) var calls: [Call] = []
    private var responses: [Any] = []
    private var conflictResponses: [Any] = []
    private var rawResponses: [(Data, HTTPURLResponse)] = []
    private var errors: [Error?] = []

    // MARK: - Configuration

    /// Queue a typed response for the next `request()` call.
    func enqueue<T: Encodable>(_ response: T) {
        let data = try! JSONEncoder().encode(response)
        responses.append(data)
    }

    /// Queue raw response data for the next `rawRequest()` call.
    func enqueueRaw(data: Data, statusCode: Int = 200) {
        let response = HTTPURLResponse(
            url: URL(string: "http://mock")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        rawResponses.append((data, response))
    }

    /// Queue an error for the next call.
    func enqueueError(_ error: Error) {
        errors.append(error)
    }

    // MARK: - Transport Protocol

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        let bodyData = body.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }
        calls.append(Call(method: method, path: path, body: bodyData, query: query))

        if let error = errors.first {
            errors.removeFirst()
            throw error!
        }

        guard !responses.isEmpty else {
            fatalError("MockTransport: no response queued for \(method.rawValue) \(path)")
        }

        let data = responses.removeFirst() as! Data
        return try JSONDecoder().decode(T.self, from: data)
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        let bodyData = body.flatMap { try? JSONEncoder().encode(AnyEncodable($0)) }
        calls.append(Call(method: method, path: path, body: bodyData, query: query))

        if let error = errors.first {
            errors.removeFirst()
            throw error!
        }

        guard !responses.isEmpty else {
            fatalError("MockTransport: no response queued for \(method.rawValue) \(path)")
        }

        let data = responses.removeFirst() as! Data

        // Try to decode as the expected type first
        if let result = try? JSONDecoder().decode(T.self, from: data) {
            return .success(result)
        }

        // Try conflict response
        if let conflict = try? JSONDecoder().decode(ConflictResponse.self, from: data) {
            return .conflict(conflict)
        }

        let result = try JSONDecoder().decode(T.self, from: data)
        return .success(result)
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        calls.append(Call(method: method, path: path, body: body, query: query))

        if let error = errors.first {
            errors.removeFirst()
            throw error!
        }

        guard !rawResponses.isEmpty else {
            fatalError("MockTransport: no raw response queued for \(method.rawValue) \(path)")
        }

        return rawResponses.removeFirst()
    }
}
