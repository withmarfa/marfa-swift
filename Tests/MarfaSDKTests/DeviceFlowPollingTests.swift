import Testing
import Foundation
@testable import MarfaSDK
@testable import MarfaSDKTestSupport

/// Unit tests for ``DeviceFlow`` — the polling loop on
/// ``DeviceFlowHandle/awaitToken()`` and the ``DeviceFlow/start(...)``
/// device-authorization request.
///
/// All HTTP goes through ``FakeDeviceFlowHTTPClient`` and all time
/// through ``ManualDeviceFlowClock``, so the suite runs in milliseconds
/// with no real sleeps or network. Safe for parallel execution.
@Suite("DeviceFlow polling", .serialized, .timeLimit(.minutes(1)))
struct DeviceFlowPollingTests {

    // MARK: - Helpers

    private static let issuer = URL(string: "https://device-flow.example.test")!

    /// Builds a `DeviceFlowHandle` wired to per-test fakes. `expiresAt`
    /// defaults to 30 minutes ahead of the manual clock's `now()`.
    private func makeHandle(
        initialInterval: Int = 5,
        expiresIn: TimeInterval = 1800
    ) -> (DeviceFlowHandle, FakeDeviceFlowHTTPClient, ManualDeviceFlowClock, InMemoryKeychain) {
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        let handle = DeviceFlowHandle(
            issuer: Self.issuer,
            clientId: "test-client",
            deviceCode: "test-device-code",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://device-flow.example.test/device")!,
            verificationURIComplete: nil,
            expiresAt: clock.now().addingTimeInterval(expiresIn),
            interval: initialInterval,
            endpoints: Self.stubEndpoints,
            storage: storage,
            httpClient: http,
            clock: clock
        )
        return (handle, http, clock, storage)
    }

    /// Pre-resolved endpoints injected directly into the handle so the
    /// polling tests don't need to script discovery responses for every
    /// case — discovery is exercised by the start() tests.
    private static let stubEndpoints = OAuthDiscovery.Endpoints(
        token: URL(string: "https://device-flow.example.test/auth/oauth2/token")!,
        authorize: URL(string: "https://device-flow.example.test/auth/oauth2/authorize")!,
        revoke: URL(string: "https://device-flow.example.test/auth/oauth2/revoke")!,
        deviceAuthorize: URL(string: "https://device-flow.example.test/auth/device")!
    )

    /// Wire-shape discovery doc the SDK reads on first `start()` call.
    /// Tests for `DeviceFlow.start()` enqueue this ahead of their
    /// device-code response.
    ///
    /// Built from the **server URL** the test passes to `start()`, because that
    /// is the value a caller now has: the document has to publish the issuer the
    /// SDK derives from it — `<server>/auth` — or RFC 8414 §3.3 refuses it before
    /// the device-code request goes out. Endpoints hang off the server, so a test
    /// taking its own origin still sees a self-consistent document and can assert
    /// on the URLs the SDK ends up calling.
    private struct DiscoveryDoc: Encodable {
        let issuer: String
        let authorization_endpoint: String
        let token_endpoint: String
        let revocation_endpoint: String
        let device_authorization_endpoint: String

        init(serverURL: URL) {
            let origin = serverURL.absoluteString
            self.issuer = OAuthDiscovery.issuer(forServer: serverURL).absoluteString
            self.authorization_endpoint = "\(origin)/auth/oauth2/authorize"
            self.token_endpoint = "\(origin)/auth/oauth2/token"
            self.revocation_endpoint = "\(origin)/auth/oauth2/revoke"
            self.device_authorization_endpoint = "\(origin)/auth/device"
        }
    }

    // MARK: - Polling loop

    @Test("success after one authorization_pending response")
    func successAfterPending() async throws {
        let (handle, http, clock, storage) = makeHandle(initialInterval: 5)
        http.enqueueOAuthError(code: "authorization_pending")
        http.enqueueTokenResponse(accessToken: "real-access-token")

        let task = Task { try await handle.awaitToken() }

        // Cycle 1: sleep → pending response.
        #expect(await clock.nextSleepRequest() == 5)
        clock.advance(by: 5)
        // Cycle 2: sleep → token granted.
        #expect(await clock.nextSleepRequest() == 5)
        clock.advance(by: 5)

        _ = try await task.value

        #expect(http.calls.count == 2)
        // Cadence held steady — authorization_pending must not escalate.
        #expect(clock.recordedSleeps == [5, 5])
        // Token persisted under the canonical issuer+client storage key.
        let storageKey = OAuthIssuer.storageKey(
            kind: "tokens",
            issuer: Self.issuer,
            clientId: "test-client"
        )
        let stored = await storage.peek(account: storageKey)
        #expect(stored != nil)
        #expect(stored?.contains("real-access-token") == true)
    }

    @Test("device-flow tokens are isolated by issuer scheme, port, and path")
    func issuerIdentityIsolatesStoredTokens() async throws {
        let storage = InMemoryKeychain()
        let issuerA = URL(string: "https://device-flow.example.test:8443/space-a")!
        let issuerB = URL(string: "http://device-flow.example.test:9443/space-b")!
        let httpA = FakeDeviceFlowHTTPClient()
        let httpB = FakeDeviceFlowHTTPClient()
        let clockA = ManualDeviceFlowClock()
        let clockB = ManualDeviceFlowClock()
        httpA.enqueueTokenResponse(accessToken: "token-a")
        httpB.enqueueTokenResponse(accessToken: "token-b")

        let handleA = DeviceFlowHandle(
            issuer: issuerA,
            clientId: "test-client",
            deviceCode: "device-a",
            userCode: "AAAA-BBBB",
            verificationURI: URL(string: "https://device-flow.example.test/device")!,
            verificationURIComplete: nil,
            expiresAt: clockA.now().addingTimeInterval(1800),
            interval: 5,
            endpoints: Self.stubEndpoints,
            storage: storage,
            httpClient: httpA,
            clock: clockA
        )
        let handleB = DeviceFlowHandle(
            issuer: issuerB,
            clientId: "test-client",
            deviceCode: "device-b",
            userCode: "CCCC-DDDD",
            verificationURI: URL(string: "https://device-flow.example.test/device")!,
            verificationURIComplete: nil,
            expiresAt: clockB.now().addingTimeInterval(1800),
            interval: 5,
            endpoints: Self.stubEndpoints,
            storage: storage,
            httpClient: httpB,
            clock: clockB
        )

        let tokenA = Task { try await handleA.awaitToken() }
        let tokenB = Task { try await handleB.awaitToken() }
        #expect(await clockA.nextSleepRequest() == 5)
        #expect(await clockB.nextSleepRequest() == 5)
        clockA.advance(by: 5)
        clockB.advance(by: 5)
        #expect(try await tokenA.value.currentToken().accessToken == "token-a")
        #expect(try await tokenB.value.currentToken().accessToken == "token-b")
        let keyA = OAuthIssuer.storageKey(kind: "tokens", issuer: issuerA, clientId: "test-client")
        let keyB = OAuthIssuer.storageKey(kind: "tokens", issuer: issuerB, clientId: "test-client")
        #expect(await storage.peek(account: keyA)?.contains("token-a") == true)
        #expect(await storage.peek(account: keyB)?.contains("token-b") == true)
    }

    @Test("start never migrates a legacy origin-only token key")
    func startDoesNotMigrateLegacyTokenKey() async throws {
        struct RootServerDiscoveryDoc: Encodable {
            let issuer: String
            let authorization_endpoint = "https://device-flow.example.test/auth/oauth2/authorize"
            let token_endpoint = "https://device-flow.example.test/auth/oauth2/token"
            let revocation_endpoint = "https://device-flow.example.test/auth/oauth2/revoke"
            let device_authorization_endpoint = "https://device-flow.example.test/auth/device"
        }

        // A root server: HTTPS, no port, no path. That is the shape the legacy
        // migration guard calls unambiguous, so nothing here is stopping the
        // promotion except that `start()` never attempts one.
        let serverURL = URL(string: "https://device-flow.example.test")!
        let issuer = OAuthDiscovery.issuer(forServer: serverURL)
        let storage = InMemoryKeychain()
        let legacyKey = OAuthIssuer.legacyTokenStorageKey(issuer: issuer, clientId: "test-client")
        let canonicalKey = OAuthIssuer.storageKey(kind: "tokens", issuer: issuer, clientId: "test-client")
        try await storage.set("legacy-token", for: legacyKey)
        await OAuthDiscovery.shared.reset(for: issuer)
        let http = FakeDeviceFlowHTTPClient()
        try http.enqueueJSON(RootServerDiscoveryDoc(issuer: issuer.absoluteString))
        http.enqueueDeviceCodeResponse()

        _ = try await DeviceFlow.start(
            serverURL: serverURL,
            clientId: "test-client",
            scopes: ["core.note:read"],
            storage: storage,
            httpClient: http,
            clock: ManualDeviceFlowClock()
        )

        #expect(await storage.peek(account: canonicalKey) == nil)
        #expect(await storage.peek(account: legacyKey) == "legacy-token")
    }

    @Test("slow_down increments interval by 5 per RFC 8628")
    func slowDownIncrementsInterval() async throws {
        let (handle, http, clock, _) = makeHandle(initialInterval: 5)
        http.enqueueOAuthError(code: "slow_down")
        http.enqueueTokenResponse()

        let task = Task { try await handle.awaitToken() }

        // Cycle 1: 5s sleep → slow_down → interval becomes 10.
        #expect(await clock.nextSleepRequest() == 5)
        clock.advance(by: 5)
        // Cycle 2: 10s sleep → token.
        #expect(await clock.nextSleepRequest() == 10)
        clock.advance(by: 10)

        _ = try await task.value

        #expect(http.calls.count == 2)
        #expect(clock.recordedSleeps == [5, 10])
    }

    @Test("authorization_pending keeps polling at the configured cadence")
    func authorizationPendingKeepsCadence() async throws {
        let (handle, http, clock, _) = makeHandle(initialInterval: 5)
        http.enqueueOAuthError(code: "authorization_pending")
        http.enqueueOAuthError(code: "authorization_pending")
        http.enqueueOAuthError(code: "authorization_pending")
        http.enqueueTokenResponse()

        let task = Task { try await handle.awaitToken() }

        for _ in 0..<4 {
            #expect(await clock.nextSleepRequest() == 5)
            clock.advance(by: 5)
        }

        _ = try await task.value

        #expect(http.calls.count == 4)
        #expect(clock.recordedSleeps == [5, 5, 5, 5])
    }

    @Test("expired_token response surfaces DeviceFlowError and stops polling")
    func expiredTokenSurfacesAndStops() async throws {
        let (handle, http, clock, _) = makeHandle(initialInterval: 5)
        http.enqueueOAuthError(code: "expired_token")

        let task = Task { try await handle.awaitToken() }
        #expect(await clock.nextSleepRequest() == 5)
        clock.advance(by: 5)

        await #expect(throws: DeviceFlowError.self) {
            _ = try await task.value
        }

        // One HTTP call only — loop terminated after the permanent error.
        #expect(http.calls.count == 1)
        #expect(clock.recordedSleeps == [5])
    }

    @Test("access_denied response surfaces DeviceFlowError and stops polling")
    func accessDeniedSurfacesAndStops() async throws {
        let (handle, http, clock, _) = makeHandle(initialInterval: 5)
        http.enqueueOAuthError(code: "access_denied")

        let task = Task { try await handle.awaitToken() }
        #expect(await clock.nextSleepRequest() == 5)
        clock.advance(by: 5)

        let thrown: Error
        do {
            _ = try await task.value
            Issue.record("expected DeviceFlowError; got success")
            return
        } catch {
            thrown = error
        }
        let deviceErr = try #require(thrown as? DeviceFlowError)
        #expect(deviceErr.deviceCode == .accessDenied)

        #expect(http.calls.count == 1)
    }

    @Test("unknown OAuth error surfaces as OAuthError, not DeviceFlowError")
    func unknownOAuthErrorSurfacesAsOAuthError() async throws {
        let (handle, http, clock, _) = makeHandle(initialInterval: 5)
        // `invalid_grant` is a generic RFC 6749 §5.2 code, not in the
        // RFC 8628 device-flow code set — must propagate as OAuthError.
        http.enqueueOAuthError(code: "invalid_grant", description: "bad request")

        let task = Task { try await handle.awaitToken() }
        #expect(await clock.nextSleepRequest() == 5)
        clock.advance(by: 5)

        let thrown: Error
        do {
            _ = try await task.value
            Issue.record("expected OAuthError; got success")
            return
        } catch {
            thrown = error
        }
        // OAuthError, not DeviceFlowError — generic codes don't classify.
        #expect(thrown is OAuthError)
        #expect((thrown as? DeviceFlowError) == nil)
        #expect(http.calls.count == 1)
    }

    @Test("local expiry check short-circuits before any HTTP call")
    func localExpiryShortCircuitsBeforePoll() async throws {
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        // Already-expired handle: expiresAt is 1s in the *past*.
        let handle = DeviceFlowHandle(
            issuer: Self.issuer,
            clientId: "test-client",
            deviceCode: "code",
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://device-flow.example.test/device")!,
            verificationURIComplete: nil,
            expiresAt: clock.now().addingTimeInterval(-1),
            interval: 5,
            endpoints: Self.stubEndpoints,
            storage: storage,
            httpClient: http,
            clock: clock
        )

        await #expect(throws: DeviceFlowError.self) {
            _ = try await handle.awaitToken()
        }

        // No HTTP call, no sleep — the loop exits on the first
        // `clock.now() >= expiresAt` check.
        #expect(http.calls.isEmpty)
        #expect(clock.recordedSleeps.isEmpty)
    }

    @Test("transport error propagates from awaitToken")
    func transportErrorPropagates() async throws {
        let (handle, http, clock, _) = makeHandle(initialInterval: 5)
        http.enqueueError(URLError(.notConnectedToInternet))

        let task = Task { try await handle.awaitToken() }
        #expect(await clock.nextSleepRequest() == 5)
        clock.advance(by: 5)

        do {
            _ = try await task.value
            Issue.record("expected URLError; got success")
            return
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("expected URLError; got \(type(of: error)): \(error)")
        }
        #expect(http.calls.count == 1)
    }

    @Test("Task.cancel() during sleep surfaces CancellationError")
    func cancellationThrowsCancellationError() async throws {
        let (handle, http, clock, _) = makeHandle(initialInterval: 5)

        let task = Task { try await handle.awaitToken() }
        // Wait until the loop is suspended inside sleep, then cancel.
        _ = await clock.nextSleepRequest()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        // No HTTP call ever happened — cancellation hit during the
        // first sleep, before any poll.
        #expect(http.calls.isEmpty)
    }

    // MARK: - DeviceFlow.start

    @Test("start() decodes the device-code response into a populated handle")
    func startSuccessParsesResponse() async throws {
        let serverURL = uniqueServerURL("device-flow-start")
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        try http.enqueueJSON(DiscoveryDoc(serverURL: serverURL))
        http.enqueueDeviceCodeResponse(
            deviceCode: "DC-1234",
            userCode: "WDJB-MJHT",
            verificationURI: "https://device-flow.example.test/device",
            verificationURIComplete: "https://device-flow.example.test/device?user_code=WDJB-MJHT",
            expiresInSeconds: 1800,
            interval: 5
        )

        let handle = try await DeviceFlow.start(
            serverURL: serverURL,
            clientId: "test-client",
            scopes: ["core.note:read"],
            storage: storage,
            httpClient: http,
            clock: clock
        )

        #expect(handle.userCode == "WDJB-MJHT")
        #expect(handle.verificationURI == URL(string: "https://device-flow.example.test/device"))
        #expect(handle.verificationURIComplete == URL(string: "https://device-flow.example.test/device?user_code=WDJB-MJHT"))
        #expect(handle.expiresAt == clock.now().addingTimeInterval(1800))

        // Request shape: discovery first, then POST /auth/device with
        // the expected JSON body.
        #expect(http.calls.count == 2)
        let request = try #require(http.calls.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url == serverURL.appendingPathComponent("auth/device"))
        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["client_id"] as? String == "test-client")
        #expect(decoded["scope"] as? String == "core.note:read")
    }

    @Test("start() throws OAuthError on a non-2xx response")
    func startOAuthErrorIsParsed() async throws {
        let serverURL = uniqueServerURL("device-flow-start")
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        try http.enqueueJSON(DiscoveryDoc(serverURL: serverURL))
        http.enqueueOAuthError(code: "invalid_client", description: "no such client")

        let thrown: Error
        do {
            _ = try await DeviceFlow.start(
                serverURL: serverURL,
                clientId: "test-client",
                scopes: ["core.note:read"],
                storage: storage,
                httpClient: http,
                clock: clock
            )
            Issue.record("expected OAuthError; got success")
            return
        } catch {
            thrown = error
        }
        let oauth = try #require(thrown as? OAuthError)
        #expect(oauth.code == "invalid_client")
        #expect(oauth.message == "no such client")
    }

    @Test("start() defaults interval to 5 when the server omits it")
    func startDefaultsIntervalWhenMissing() async throws {
        let serverURL = uniqueServerURL("device-flow-start")
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        // RFC 8628 says `interval` is optional; SDK must default to 5s.
        try http.enqueueJSON(DiscoveryDoc(serverURL: serverURL))
        http.enqueueDeviceCodeResponse(interval: nil)

        let handle = try await DeviceFlow.start(
            serverURL: serverURL,
            clientId: "test-client",
            scopes: ["core.note:read"],
            storage: storage,
            httpClient: http,
            clock: clock
        )

        // Drive one poll cycle and assert the very first sleep was 5s.
        http.enqueueTokenResponse()
        let task = Task { try await handle.awaitToken() }
        #expect(await clock.nextSleepRequest() == 5)
        clock.advance(by: 5)
        _ = try await task.value
    }

    @Test("start() leaves verification_uri_complete nil when the server omits it")
    func startVerificationURICompleteOptional() async throws {
        let serverURL = uniqueServerURL("device-flow-start")
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        try http.enqueueJSON(DiscoveryDoc(serverURL: serverURL))
        http.enqueueDeviceCodeResponse(
            verificationURI: "\(serverURL.absoluteString)/device",
            verificationURIComplete: nil
        )

        let handle = try await DeviceFlow.start(
            serverURL: serverURL,
            clientId: "test-client",
            scopes: ["core.note:read"],
            storage: storage,
            httpClient: http,
            clock: clock
        )

        #expect(handle.verificationURIComplete == nil)
        #expect(handle.verificationURI == URL(string: "\(serverURL.absoluteString)/device"))
    }
}
