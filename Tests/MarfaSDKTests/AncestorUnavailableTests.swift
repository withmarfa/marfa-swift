import Testing
import Foundation
@testable import MarfaSDK

/// Per-suite URLProtocol stub — see `Transport401RefreshTests` for the
/// rationale on scoped subclasses.
final class AncestorStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var nextResponse: (Int, Data)?
    private static let lock = NSLock()

    static func setHTTP(status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        nextResponse = (status, body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let response = Self.nextResponse
        Self.lock.unlock()

        guard let (status, body) = response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedTransport() -> URLSessionTransport {
    let config = ClientConfiguration(
        url: URL(string: "http://test")!,
        apiKey: "k",
        retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitter: 0)
    )
    return URLSessionTransport(
        configuration: config, protocolClasses: [AncestorStubURLProtocol.self]
    )
}

/// A write refused because the version it names has been thinned out of
/// history. **The two 409 bodies are told apart by which keys each requires**,
/// not by the order the transport tries them in — swapping that order changes
/// no behaviour, which was measured rather than assumed. Two guards hold the
/// discrimination up, `requested_version` and the single-case `code`, and
/// relaxing either one alone is survivable; relaxing both turns every merge
/// conflict into a thinned ancestor. That pair is what these pin, because the
/// compiler only objects to the first of them.
@Suite("Ancestor unavailable", .serialized)
struct AncestorUnavailableTests {

    private let thinnedBody = #"""
    {
      "error": {
        "code": "ancestor_unavailable",
        "status": 409,
        "message": "version 3 is no longer retained"
      },
      "current": { "version": 11, "properties": { "title": "server title" } },
      "requested_version": 3
    }
    """#

    private let mergeBody = #"""
    {
      "error": { "code": "version_conflict", "status": 409, "message": "Version conflict" },
      "current": { "version": 11, "properties": { "title": "server title" } },
      "ancestor": { "version": 3, "properties": { "title": "base title" } },
      "conflicting_fields": ["title"],
      "merge_policy": { "default": "last_writer_wins" }
    }
    """#

    /// The two fields a rebase needs are exactly the two this carries, and
    /// throwing them away is what made the mutation dead-letter.
    @Test("a thinned ancestor surfaces with the version and the server's copy")
    func thinnedAncestorCarriesRebaseInputs() async throws {
        AncestorStubURLProtocol.setHTTP(status: 409, body: Data(thinnedBody.utf8))
        let transport = makeStubbedTransport()

        do {
            _ = try await transport.request(
                method: .patch, path: "/items/n1", body: nil, query: nil, idempotencyKey: nil
            ) as EmptyResponse
            Issue.record("expected AncestorUnavailableError")
        } catch let error as AncestorUnavailableError {
            #expect(error.requestedVersion == 3)
            #expect(error.current.version == 11)
            #expect(error.current.properties["title"] == .string("server title"))
            #expect(error.message.contains("no longer retained"))
        }
    }

    /// **Not permanent**, which is the only reason modelling it separately
    /// earns its place: a permanent classification dead-letters an edit the
    /// server would accept rebased.
    @Test("a thinned ancestor is retryable, not permanent")
    func thinnedAncestorIsNotPermanent() {
        let error = AncestorUnavailableError(
            current: ConflictSnapshot(properties: [:], version: 11),
            requestedVersion: 3,
            message: "gone"
        )
        #expect(!error.isPermanent)
    }

    /// An ordinary merge conflict must still reach `ConflictError`. This is
    /// the direction that breaks when the thinned branch stops requiring both
    /// `requested_version` and its single-case `code`.
    @Test("an ordinary version conflict is not read as a thinned ancestor")
    func mergeConflictStillDecodesAsConflict() async throws {
        AncestorStubURLProtocol.setHTTP(status: 409, body: Data(mergeBody.utf8))
        let transport = makeStubbedTransport()

        do {
            _ = try await transport.request(
                method: .patch, path: "/items/n1", body: nil, query: nil
            ) as EmptyResponse
            Issue.record("expected ConflictError")
        } catch is AncestorUnavailableError {
            Issue.record("merge conflict decoded as a thinned ancestor")
        } catch let error as ConflictError {
            #expect(error.conflictingFields == ["title"])
            #expect(error.ancestor.version == 3)
        }
    }

    /// Neither body can decode as the other, which is the property the
    /// transport relies on and the one a later "make this field optional"
    /// would quietly remove. Asserted against the decoder directly, because
    /// through the transport a wrong decode still throws *something* and the
    /// test would pass for the wrong reason.
    @Test("neither 409 body can decode as the other")
    func theTwoBodiesAreMutuallyExclusive() {
        let decoder = JSONDecoder()
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(ConflictResponse.self, from: Data(thinnedBody.utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(AncestorUnavailableResponse.self, from: Data(mergeBody.utf8))
        }
    }

    /// The same distinction on the conflict-aware path, which carries its own
    /// copy of the branch. Two copies of one rule drift, so both are pinned.
    @Test("the conflict-aware path also surfaces a thinned ancestor")
    func conflictAwarePathSurfacesThinnedAncestor() async throws {
        AncestorStubURLProtocol.setHTTP(status: 409, body: Data(thinnedBody.utf8))
        let transport = makeStubbedTransport()

        do {
            let _: ConflictResult<EmptyResponse> = try await transport.requestWithConflict(
                method: .patch, path: "/items/n1", body: nil, query: nil, idempotencyKey: nil
            )
            Issue.record("expected AncestorUnavailableError")
        } catch let error as AncestorUnavailableError {
            #expect(error.requestedVersion == 3)
            #expect(error.current.version == 11)
        }
    }
}
