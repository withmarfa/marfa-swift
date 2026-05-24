import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("AuthNamespace — account lifecycle")
struct AuthNamespaceTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    // MARK: - requestDelete

    @Test("requestDelete POSTs /auth/account/delete with no body")
    func requestDeletePostsExpectedShape() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.auth.account.requestDelete()

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/auth/account/delete")
        #expect(mock.calls[0].body == nil)
        #expect(mock.calls[0].query == nil)
    }

    @Test("requestDelete surfaces transport errors")
    func requestDeleteSurfacesErrors() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(UnauthorizedError(message: "bad token"))

        await #expect(throws: UnauthorizedError.self) {
            try await client.auth.account.requestDelete()
        }
    }

    // MARK: - confirmDelete

    @Test("confirmDelete GETs /auth/account/delete/confirm with the token query param")
    func confirmDeleteSendsToken() async throws {
        let (client, mock) = makeClient()
        mock.enqueueRaw(data: Data(), statusCode: 200)

        try await client.auth.account.confirmDelete(token: "tok_abc")

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/auth/account/delete/confirm")
        let query = mock.calls[0].query ?? []
        #expect(query.contains(where: { $0.0 == "token" && $0.1 == "tok_abc" }))
    }

    @Test("confirmDelete throws on 404 token-invalid")
    func confirmDeleteThrowsOn404() async throws {
        let (client, mock) = makeClient()
        let body = Data("""
        {"error":{"code":"not_found","message":"token invalid or already consumed"}}
        """.utf8)
        mock.enqueueRaw(data: body, statusCode: 404)

        await #expect(throws: NotFoundError.self) {
            try await client.auth.account.confirmDelete(token: "tok_bad")
        }
    }

    @Test("confirmDelete throws on 400 token-expired (validation)")
    func confirmDeleteThrowsOn400() async throws {
        let (client, mock) = makeClient()
        let body = Data("""
        {"error":{"code":"validation_error","message":"token expired"}}
        """.utf8)
        mock.enqueueRaw(data: body, statusCode: 400)

        await #expect(throws: ValidationError.self) {
            try await client.auth.account.confirmDelete(token: "tok_expired")
        }
    }

    // MARK: - cancel

    @Test("cancel POSTs /auth/account/delete/cancel with no body")
    func cancelPostsExpectedShape() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(EmptyResponse())

        try await client.auth.account.cancel()

        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .post)
        #expect(mock.calls[0].path == "/auth/account/delete/cancel")
        #expect(mock.calls[0].body == nil)
        #expect(mock.calls[0].query == nil)
    }

    @Test("cancel surfaces transport errors")
    func cancelSurfacesErrors() async throws {
        let (client, mock) = makeClient()
        mock.enqueueError(ValidationError(message: "account not pending deletion"))

        await #expect(throws: ValidationError.self) {
            try await client.auth.account.cancel()
        }
    }

    // MARK: - Pure-local rejection

    @Test("Pure-local rejects every account-lifecycle method")
    func localModeRejects() async throws {
        let client = try await MarfaClient.local(path: ":memory:")

        await #expect(throws: LocalModeUnsupportedError.self) {
            try await client.auth.account.requestDelete()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            try await client.auth.account.confirmDelete(token: "tok")
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            try await client.auth.account.cancel()
        }
    }
}
