import Foundation

/// URLSession-based implementation of the `Transport` protocol.
final class URLSessionTransport: Transport {

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(configuration: ClientConfiguration) {
        self.baseURL = configuration.url
        self.apiKey = configuration.apiKey

        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest = configuration.timeoutInterval
        urlConfig.timeoutIntervalForResource = configuration.resourceTimeout
        self.session = URLSession(configuration: urlConfig)

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Transport Protocol

    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T {
        let bodyData = try encodeBody(body)
        let (data, response) = try await rawRequest(
            method: method, path: path, body: bodyData,
            contentType: body != nil ? "application/json" : nil, query: query
        )

        if response.statusCode == 409 {
            if let conflict = try? decoder.decode(ConflictResponse.self, from: data) {
                throw ConflictError(
                    current: conflict.current,
                    ancestor: conflict.ancestor ?? ConflictSnapshot(version: 0, properties: [:]),
                    conflictingFields: conflict.conflicting_fields,
                    clientPatch: [:]
                )
            }
            throw try parseError(data: data, statusCode: 409)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw try parseError(data: data, statusCode: response.statusCode)
        }

        if response.statusCode == 204 || data.isEmpty {
            // Attempt to decode an empty/void response — works for types like EmptyResponse
            if let result = EmptyResponse() as? T {
                return result
            }
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ResponseDecodingError(error)
        }
    }

    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T> {
        let bodyData = try encodeBody(body)
        let (data, response) = try await rawRequest(
            method: method, path: path, body: bodyData,
            contentType: body != nil ? "application/json" : nil, query: query
        )

        if response.statusCode == 409 {
            if let conflict = try? decoder.decode(ConflictResponse.self, from: data) {
                return .conflict(conflict)
            }
            throw try parseError(data: data, statusCode: 409)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw try parseError(data: data, statusCode: response.statusCode)
        }

        do {
            let result = try decoder.decode(T.self, from: data)
            return .success(result)
        } catch {
            throw ResponseDecodingError(error)
        }
    }

    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try buildURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let body {
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw NetworkError(error)
        } catch {
            throw NetworkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError(URLError(.badServerResponse))
        }

        return (data, httpResponse)
    }

    // MARK: - Private

    private func encodeBody(_ body: (any Encodable & Sendable)?) throws -> Data? {
        guard let body else { return nil }
        do {
            return try encoder.encode(body)
        } catch {
            throw MymeError(code: "encoding_error", message: "Failed to encode request body: \(error.localizedDescription)", status: 0)
        }
    }

    private func buildURL(path: String, query: [(String, String)]?) throws -> URL {
        let fullPath = baseURL.absoluteString.hasSuffix("/")
            ? baseURL.absoluteString.dropLast() + path
            : baseURL.absoluteString + path

        guard var components = URLComponents(string: String(fullPath)) else {
            throw NetworkError(URLError(.badURL))
        }

        if let query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }

        guard let url = components.url else {
            throw NetworkError(URLError(.badURL))
        }

        return url
    }

    private func parseError(data: Data, statusCode: Int) throws -> MymeError {
        let message: String
        let details: [String: JSONValue]?

        if let apiError = try? decoder.decode(APIErrorResponse.self, from: data) {
            message = apiError.error.message ?? apiError.error.code
            details = apiError.error.details
        } else {
            message = String(data: data, encoding: .utf8) ?? "Unknown error"
            details = nil
        }

        switch statusCode {
        case 400: return ValidationError(message: message, details: details)
        case 401: return UnauthorizedError(message: message, details: details)
        case 403: return ForbiddenError(message: message, details: details)
        case 404: return NotFoundError(message: message, details: details)
        default: return MymeError(code: "server_error", message: message, status: statusCode, details: details)
        }
    }
}

// MARK: - Empty Response

/// Placeholder for endpoints that return no meaningful body (DELETE, etc.).
struct EmptyResponse: Codable, Sendable {}

/// AnyEncodable wrapper for encoding arbitrary Encodable values.
struct AnyEncodable: Encodable, @unchecked Sendable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable & Sendable) {
        _encode = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
