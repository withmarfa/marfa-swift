import Foundation

/// OAuth endpoint discovery via RFC 8414 (`/.well-known/oauth-authorization-server`).
///
/// The SDK previously hardcoded `/auth/authorize`, `/auth/token`, and
/// `/auth/revoke` against the server's pre-T-131 URL layout. The server
/// migration (Better Auth OAuth Provider plugin) moved those to
/// `/auth/oauth2/{authorize,token,revoke}`. Rather than chasing URL
/// changes through hardcoded literals, the SDK now reads the canonical
/// metadata doc on first use and caches the result.
///
/// ``OAuthDiscovery/shared`` is the process-wide instance — three OAuth-
/// touching code paths (``MarfaAuth``, ``DeviceFlow``,
/// ``StoredTokenProvider``) all funnel through it, so concurrent
/// first-calls on app boot share a single in-flight fetch.
///
/// Failure is hard — ``OAuthDiscoveryError`` on HTTP, network, or schema
/// failure. No fallback to legacy paths.
public actor OAuthDiscovery {

    public static let shared = OAuthDiscovery()

    /// OAuth endpoints the SDK consumes. RFC 8414 publishes more fields;
    /// the SDK only reads the ones it uses.
    public struct Endpoints: Sendable, Equatable {
        /// `token_endpoint` — refresh + auth-code exchange.
        public let token: URL
        /// `authorization_endpoint` — `ASWebAuthenticationSession` entry point.
        public let authorize: URL
        /// `revocation_endpoint` — RFC 7009 token revocation.
        public let revoke: URL
        /// `device_authorization_endpoint` — RFC 8628 device-flow initiate.
        public let deviceAuthorize: URL
    }

    private let path = "/.well-known/oauth-authorization-server"
    private var cache: [String: Endpoints] = [:]
    private var inflight: [String: Task<Endpoints, Error>] = [:]

    public init() {}

    /// Returns the discovered endpoints for `issuer`. First call fetches
    /// the well-known doc; subsequent calls return the cached value.
    /// Concurrent first-calls share a single in-flight task.
    ///
    /// `httpClient` defaults to `URLSession.shared` for production use.
    /// Tests pass a stub conforming to ``DeviceFlowHTTPClient`` (the
    /// same seam ``DeviceFlow`` uses) so the well-known fetch lands on
    /// the test's scripted response queue.
    public func endpoints(
        for issuer: URL,
        httpClient: any DeviceFlowHTTPClient = URLSession.shared
    ) async throws -> Endpoints {
        let key = Self.normalize(issuer)
        if let cached = cache[key.absoluteString] {
            return cached
        }
        if let task = inflight[key.absoluteString] {
            return try await task.value
        }
        let task = Task { [path] in
            try await Self.fetchEndpoints(
                issuer: key,
                path: path,
                httpClient: httpClient
            )
        }
        inflight[key.absoluteString] = task
        do {
            let resolved = try await task.value
            cache[key.absoluteString] = resolved
            inflight.removeValue(forKey: key.absoluteString)
            return resolved
        } catch {
            // Evict the inflight entry on failure so a later call can
            // retry — a stuck failed task would permanently break the
            // SDK after a single network blip.
            inflight.removeValue(forKey: key.absoluteString)
            throw error
        }
    }

    /// Test-only — clears the in-actor cache. Production callers never
    /// need this; the cache is correct by construction for process
    /// lifetime.
    public func reset() {
        cache.removeAll()
        inflight.removeAll()
    }

    // MARK: - Internals

    private static func normalize(_ url: URL) -> URL {
        // Use the origin (scheme + host + port). Trailing-slash strip
        // is implicit since URL absoluteString excludes path when there
        // isn't one. For URLs with paths, fall back to the original.
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.host = url.host?.lowercased()
        components.port = url.port
        return components.url ?? url
    }

    private static func fetchEndpoints(
        issuer: URL,
        path: String,
        httpClient: any DeviceFlowHTTPClient
    ) async throws -> Endpoints {
        let discoveryURL = issuer.appendingPathComponent(path)
        var request = URLRequest(url: discoveryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            throw OAuthDiscoveryError.networkError(issuer: issuer, underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OAuthDiscoveryError.invalidResponse(issuer: issuer)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OAuthDiscoveryError.httpError(issuer: issuer, status: http.statusCode)
        }
        let doc: DiscoveryDoc
        do {
            doc = try JSONDecoder().decode(DiscoveryDoc.self, from: data)
        } catch {
            throw OAuthDiscoveryError.malformedDoc(issuer: issuer, underlying: error)
        }
        guard
            let token = doc.token_endpoint.flatMap(URL.init(string:)),
            let authorize = doc.authorization_endpoint.flatMap(URL.init(string:)),
            let revoke = doc.revocation_endpoint.flatMap(URL.init(string:)),
            let deviceAuthorize = doc.device_authorization_endpoint.flatMap(URL.init(string:))
        else {
            throw OAuthDiscoveryError.missingField(
                issuer: issuer,
                field: missingFieldName(doc)
            )
        }
        return Endpoints(
            token: token,
            authorize: authorize,
            revoke: revoke,
            deviceAuthorize: deviceAuthorize
        )
    }

    private struct DiscoveryDoc: Decodable {
        let token_endpoint: String?
        let authorization_endpoint: String?
        let revocation_endpoint: String?
        let device_authorization_endpoint: String?
    }

    private static func missingFieldName(_ doc: DiscoveryDoc) -> String {
        if doc.token_endpoint == nil { return "token_endpoint" }
        if doc.authorization_endpoint == nil { return "authorization_endpoint" }
        if doc.revocation_endpoint == nil { return "revocation_endpoint" }
        return "device_authorization_endpoint"
    }
}

/// Surfaced when ``OAuthDiscovery`` cannot resolve endpoints from the
/// server's well-known doc. No fallback to legacy paths.
public enum OAuthDiscoveryError: Error, Sendable {
    case networkError(issuer: URL, underlying: Error)
    case invalidResponse(issuer: URL)
    case httpError(issuer: URL, status: Int)
    case malformedDoc(issuer: URL, underlying: Error)
    case missingField(issuer: URL, field: String)
}

extension OAuthDiscoveryError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .networkError(let issuer, let underlying):
            return "OAuth discovery network error against \(issuer.absoluteString): \(underlying)"
        case .invalidResponse(let issuer):
            return "OAuth discovery received a non-HTTP response from \(issuer.absoluteString)"
        case .httpError(let issuer, let status):
            return "OAuth discovery returned HTTP \(status) from \(issuer.absoluteString)"
        case .malformedDoc(let issuer, let underlying):
            return "OAuth discovery doc was not valid JSON from \(issuer.absoluteString): \(underlying)"
        case .missingField(let issuer, let field):
            return "OAuth discovery doc from \(issuer.absoluteString) is missing required field \"\(field)\""
        }
    }
}
