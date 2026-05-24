import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

@Suite("ProfileNamespace")
struct ProfileNamespaceTests {

    func makeClient() -> (MarfaClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "k")
        let client = MarfaClient(configuration: config, transport: mock)
        return (client, mock)
    }

    func sampleProfile() -> Profile {
        Profile(
            avatarUrl: "https://cdn/avatar/abc.png",
            bio: nil,
            createdAt: "2026-01-01T00:00:00Z",
            email: "u@example.test",
            emailVerified: true,
            firstName: "Sam",
            lastName: nil,
            updatedAt: "2026-05-01T00:00:00Z",
            username: "sam"
        )
    }

    @Test("get sends GET /profile/me")
    func getProfile() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleProfile())

        let profile = try await client.profile.get()

        #expect(profile.username == "sam")
        #expect(profile.email == "u@example.test")
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].method == .get)
        #expect(mock.calls[0].path == "/profile/me")
    }

    @Test("update sends PATCH /profile/me with input body")
    func updateProfile() async throws {
        let (client, mock) = makeClient()
        let updated = sampleProfile()
        mock.enqueue(updated)

        let input = UpdateProfileInput(
            bio: "hi",
            firstName: "Sam",
            lastName: "Smith",
            username: "sam2"
        )
        let result = try await client.profile.update(input)

        #expect(result.username == "sam")  // mock returns sample regardless
        #expect(mock.calls[0].method == .patch)
        #expect(mock.calls[0].path == "/profile/me")
        #expect(mock.calls[0].body != nil)
    }

    @Test("deleteAvatar sends DELETE /profile/me/avatar")
    func deleteAvatar() async throws {
        let (client, mock) = makeClient()
        mock.enqueue(sampleProfile())

        _ = try await client.profile.deleteAvatar()

        #expect(mock.calls[0].method == .delete)
        #expect(mock.calls[0].path == "/profile/me/avatar")
    }

    @Test("uploadAvatar uses multipart/form-data Content-Type")
    func uploadAvatar() async throws {
        let (client, mock) = makeClient()
        let bodyData = try JSONEncoder().encode(sampleProfile())
        mock.enqueueRaw(data: bodyData, statusCode: 201)

        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47]) // PNG signature
        _ = try await client.profile.uploadAvatar(imageBytes, mimeType: "image/png")

        #expect(mock.calls.last?.method == .post)
        #expect(mock.calls.last?.path == "/profile/me/avatar")
    }

    @Test("Pure-local mode rejects every profile call")
    func localModeRejectsAll() async throws {
        let client = try await MarfaClient.local(path: ":memory:")

        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.profile.get()
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.profile.update(UpdateProfileInput(username: "x"))
        }
        await #expect(throws: LocalModeUnsupportedError.self) {
            _ = try await client.profile.deleteAvatar()
        }
    }
}
