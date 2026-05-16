import Testing
import Foundation
@testable import MymeSDK
@testable import MymeSDKTestSupport

/// Unit tests for ``DeviceFlow`` — the polling loop on
/// ``DeviceFlowHandle/awaitToken()`` and the ``DeviceFlow/start(...)``
/// device-authorization request.
///
/// All HTTP goes through ``FakeDeviceFlowHTTPClient`` and all time
/// through ``ManualDeviceFlowClock``, so the suite runs in milliseconds
/// with no real sleeps or network. Safe for parallel execution.
@Suite("DeviceFlow polling")
struct DeviceFlowPollingTests {

    // MARK: - Helpers

    private static let issuer = URL(string: "https://example.test")!

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
            verificationURI: URL(string: "https://example.test/device")!,
            verificationURIComplete: nil,
            expiresAt: clock.now().addingTimeInterval(expiresIn),
            interval: initialInterval,
            storage: storage,
            httpClient: http,
            clock: clock
        )
        return (handle, http, clock, storage)
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
        // Token persisted under the issuer+client storage key.
        let stored = await storage.peek(account: "myme.auth.tokens:example.test:test-client")
        #expect(stored != nil)
        #expect(stored?.contains("real-access-token") == true)
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
            verificationURI: URL(string: "https://example.test/device")!,
            verificationURIComplete: nil,
            expiresAt: clock.now().addingTimeInterval(-1),
            interval: 5,
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
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        http.enqueueDeviceCodeResponse(
            deviceCode: "DC-1234",
            userCode: "WDJB-MJHT",
            verificationURI: "https://example.test/device",
            verificationURIComplete: "https://example.test/device?user_code=WDJB-MJHT",
            expiresInSeconds: 1800,
            interval: 5
        )

        let handle = try await DeviceFlow.start(
            issuer: Self.issuer,
            clientId: "test-client",
            scopes: ["core.note:read"],
            storage: storage,
            httpClient: http,
            clock: clock
        )

        #expect(handle.userCode == "WDJB-MJHT")
        #expect(handle.verificationURI == URL(string: "https://example.test/device"))
        #expect(handle.verificationURIComplete == URL(string: "https://example.test/device?user_code=WDJB-MJHT"))
        #expect(handle.expiresAt == clock.now().addingTimeInterval(1800))

        // Request shape: POST /auth/device with the expected JSON body.
        #expect(http.calls.count == 1)
        let request = try #require(http.calls.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == Self.issuer.appendingPathComponent("auth/device"))
        let body = try #require(request.httpBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["client_id"] as? String == "test-client")
        #expect(decoded["scope"] as? String == "core.note:read")
    }

    @Test("start() throws OAuthError on a non-2xx response")
    func startOAuthErrorIsParsed() async throws {
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        http.enqueueOAuthError(code: "invalid_client", description: "no such client")

        let thrown: Error
        do {
            _ = try await DeviceFlow.start(
                issuer: Self.issuer,
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
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        // RFC 8628 says `interval` is optional; SDK must default to 5s.
        http.enqueueDeviceCodeResponse(interval: nil)

        let handle = try await DeviceFlow.start(
            issuer: Self.issuer,
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
        let http = FakeDeviceFlowHTTPClient()
        let clock = ManualDeviceFlowClock()
        let storage = InMemoryKeychain()
        http.enqueueDeviceCodeResponse(verificationURIComplete: nil)

        let handle = try await DeviceFlow.start(
            issuer: Self.issuer,
            clientId: "test-client",
            scopes: ["core.note:read"],
            storage: storage,
            httpClient: http,
            clock: clock
        )

        #expect(handle.verificationURIComplete == nil)
        #expect(handle.verificationURI == URL(string: "https://example.test/device"))
    }
}
