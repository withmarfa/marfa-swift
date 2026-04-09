import Foundation

/// Transport layer for HTTP communication with the Myme API.
///
/// Implement this protocol to inject mock transports in tests.
public protocol Transport: Sendable {

    /// Sends a JSON request and decodes the response.
    func request<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> T

    /// Sends a JSON request that may return a 409 conflict.
    /// Returns `.success` with the decoded response, or `.failure` with conflict data.
    func requestWithConflict<T: Decodable & Sendable>(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)?,
        query: [(String, String)]?
    ) async throws -> ConflictResult<T>

    /// Sends a raw HTTP request and returns the response data and metadata.
    func rawRequest(
        method: HTTPMethod,
        path: String,
        body: Data?,
        contentType: String?,
        query: [(String, String)]?
    ) async throws -> (Data, HTTPURLResponse)
}
