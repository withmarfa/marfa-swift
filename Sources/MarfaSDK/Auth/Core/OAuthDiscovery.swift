import Foundation

/// OAuth endpoint discovery via RFC 8414 (`/.well-known/oauth-authorization-server`).
///
/// The SDK reads OAuth endpoints from the server's canonical well-known
/// metadata document on first use and caches the result, rather than
/// relying on hardcoded URL paths that could diverge from the server layout.
///
/// ``OAuthDiscovery/shared`` is the process-wide instance — three OAuth-
/// touching code paths (``MarfaAuth``, ``DeviceFlow``,
/// ``StoredTokenProvider``) all funnel through it, so concurrent
/// first-calls on app boot share a single in-flight fetch.
///
/// Failure is hard — ``OAuthDiscoveryError`` on HTTP, network, or schema
/// failure. Endpoint discovery is required; there is no fallback.
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

    /// A resolved well-known document: the endpoints the SDK consumes plus the
    /// `issuer` the server published. The published issuer is retained because
    /// the cache is keyed on the canonical issuer while RFC 8414 §3.3 requires
    /// the published value to be identical to the issuer identifier *as the
    /// caller asked for it*. Two spellings of one server therefore share a
    /// fetch but are each checked on their own terms.
    private struct ResolvedMetadata: Sendable {
        let endpoints: Endpoints
        let metadataIssuer: String
    }

    private var cache: [String: ResolvedMetadata] = [:]
    private struct InflightRequest {
        let id: UUID
        let task: Task<ResolvedMetadata, Error>
    }
    private var inflight: [String: InflightRequest] = [:]

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
        let key = try OAuthIssuer.canonicalURL(issuer)
        if let cached = cache[key.absoluteString] {
            return try Self.verify(cached, requestedIssuer: issuer)
        }
        if let request = inflight[key.absoluteString] {
            return try Self.verify(
                try await request.task.value,
                requestedIssuer: issuer
            )
        }
        let requestID = UUID()
        let task = Task { [path] in
            try await Self.fetchMetadata(
                issuer: key,
                requestedIssuer: issuer,
                path: path,
                httpClient: httpClient
            )
        }
        inflight[key.absoluteString] = InflightRequest(id: requestID, task: task)
        do {
            let resolved = try await task.value
            // A test reset may have cancelled and replaced this request while
            // its HTTP client ignored cancellation. Only the request that still
            // owns the key may publish into the cache or clear the in-flight slot.
            if inflight[key.absoluteString]?.id == requestID {
                cache[key.absoluteString] = resolved
                inflight.removeValue(forKey: key.absoluteString)
            }
            return try Self.verify(resolved, requestedIssuer: issuer)
        } catch {
            // Evict the inflight entry on failure so a later call can
            // retry — a stuck failed task would permanently break the
            // SDK after a single network blip.
            if inflight[key.absoluteString]?.id == requestID {
                inflight.removeValue(forKey: key.absoluteString)
            }
            throw error
        }
    }

    /// Test-only — clears every cached issuer while preserving the original
    /// public symbol for source and binary compatibility.
    public func reset() {
        for request in inflight.values {
            request.task.cancel()
        }
        cache.removeAll()
        inflight.removeAll()
    }

    /// Issuer-scoped test seam. Internal so cache control does not expand the
    /// SDK's public API; package tests reach it through `@testable import`.
    internal func reset(for issuer: URL) {
        guard let key = try? OAuthIssuer.canonicalURL(issuer).absoluteString else {
            return
        }
        cache.removeValue(forKey: key)
        inflight.removeValue(forKey: key)?.task.cancel()
    }

    // MARK: - Internals

    /// RFC 8414 §3.3: the published `issuer` must be identical to the issuer
    /// identifier the caller asked for. The canonical form drives storage and
    /// cache keys only — normalizing the comparison would both reject servers
    /// whose issuer identifier legitimately ends in `/` and accept a document
    /// that merely resembles the request.
    private static func verify(
        _ resolved: ResolvedMetadata,
        requestedIssuer: URL
    ) throws -> Endpoints {
        guard resolved.metadataIssuer == requestedIssuer.absoluteString else {
            throw OAuthDiscoveryError.malformedDoc(
                issuer: requestedIssuer,
                underlying: MetadataIssuerMismatch(
                    metadataIssuer: resolved.metadataIssuer,
                    requestedIssuer: requestedIssuer.absoluteString
                )
            )
        }
        return resolved.endpoints
    }

    private static func fetchMetadata(
        issuer: URL,
        requestedIssuer: URL,
        path: String,
        httpClient: any DeviceFlowHTTPClient
    ) async throws -> ResolvedMetadata {
        let discoveryURL = wellKnownURL(for: issuer, path: path)
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
        guard doc.issuer == requestedIssuer.absoluteString else {
            throw OAuthDiscoveryError.malformedDoc(
                issuer: requestedIssuer,
                underlying: MetadataIssuerMismatch(
                    metadataIssuer: doc.issuer,
                    requestedIssuer: requestedIssuer.absoluteString
                )
            )
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
        return ResolvedMetadata(
            endpoints: Endpoints(
                token: token,
                authorize: authorize,
                revoke: revoke,
                deviceAuthorize: deviceAuthorize
            ),
            metadataIssuer: doc.issuer
        )
    }

    private struct DiscoveryDoc: Decodable {
        let issuer: String
        let token_endpoint: String?
        let authorization_endpoint: String?
        let revocation_endpoint: String?
        let device_authorization_endpoint: String?
    }

    /// RFC 8414 places the well-known path before an issuer path component:
    /// `https://host/.well-known/oauth-authorization-server/space`.
    private static func wellKnownURL(for issuer: URL, path: String) -> URL {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else {
            return issuer.appendingPathComponent(path)
        }

        let issuerPath = components.percentEncodedPath
        components.percentEncodedPath = path + issuerPath
        components.query = nil
        components.fragment = nil
        return components.url ?? issuer.appendingPathComponent(path)
    }

    private static func missingFieldName(_ doc: DiscoveryDoc) -> String {
        if doc.token_endpoint == nil { return "token_endpoint" }
        if doc.authorization_endpoint == nil { return "authorization_endpoint" }
        if doc.revocation_endpoint == nil { return "revocation_endpoint" }
        return "device_authorization_endpoint"
    }

    private struct MetadataIssuerMismatch: Error, CustomStringConvertible {
        let metadataIssuer: String
        let requestedIssuer: String

        var description: String {
            "metadata issuer \(metadataIssuer) does not match the requested issuer \(requestedIssuer)"
        }
    }
}

/// Surfaced when ``OAuthDiscovery`` cannot resolve endpoints from the
/// server's well-known doc. Endpoint discovery is required; there is no
/// fallback.
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
            return "OAuth discovery metadata from \(issuer.absoluteString) is invalid: \(underlying)"
        case .missingField(let issuer, let field):
            return "OAuth discovery doc from \(issuer.absoluteString) is missing required field \"\(field)\""
        }
    }
}
