import Testing
import Foundation
@testable import MymeSDK

@Suite("BlobsNamespace")
struct BlobsTests {

    func makeClient() -> (MymeClient, MockTransport) {
        let mock = MockTransport()
        let config = ClientConfiguration(url: URL(string: "http://test")!, apiKey: "test-key")
        let client = MymeClient(configuration: config, transport: mock)
        return (client, mock)
    }

    @Test("Upload success decodes BlobUploadResponse")
    func uploadSuccess() async throws {
        let (client, mock) = makeClient()
        let body = #"{"hash":"sha256:abc","size":100,"mime_type":"image/png"}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 201)

        let result = try await client.blobs.upload(data: Data([0x89, 0x50, 0x4e, 0x47]), mimeType: "image/png")

        #expect(result.hash == "sha256:abc")
    }

    @Test("Upload 401 produces UnauthorizedError via shared parser")
    func uploadUnauthorized() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"unauthorized","message":"Invalid token"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 401)

        await #expect(throws: UnauthorizedError.self) {
            _ = try await client.blobs.upload(data: Data(), mimeType: "image/png")
        }
    }

    @Test("Upload 500 produces base MymeError with status 500")
    func uploadServerError() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"internal","message":"Database down"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 500)

        do {
            _ = try await client.blobs.upload(data: Data(), mimeType: "image/png")
            Issue.record("Expected error")
        } catch let error as MymeError {
            #expect(error.status == 500)
            #expect(error.message == "Database down")
        }
    }

    @Test("Download 401 produces UnauthorizedError (not NotFoundError)")
    func downloadUnauthorized() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"unauthorized","message":"No key"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 401)

        await #expect(throws: UnauthorizedError.self) {
            _ = try await client.blobs.download(hash: "abc")
        }
    }

    @Test("Download 403 produces ForbiddenError")
    func downloadForbidden() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"forbidden","message":"Not allowed"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 403)

        await #expect(throws: ForbiddenError.self) {
            _ = try await client.blobs.download(hash: "abc")
        }
    }

    @Test("Download 404 still produces NotFoundError")
    func downloadNotFound() async throws {
        let (client, mock) = makeClient()
        let body = #"{"error":{"code":"not_found","message":"Missing"}}"#
        mock.enqueueRaw(data: Data(body.utf8), statusCode: 404)

        await #expect(throws: NotFoundError.self) {
            _ = try await client.blobs.download(hash: "abc")
        }
    }

    @Test("Download success returns data and content type")
    func downloadSuccess() async throws {
        let (client, mock) = makeClient()
        let payload = Data([0x01, 0x02, 0x03])
        // MockTransport.enqueueRaw sets Content-Type to application/json;
        // the download method still reads it from the response header.
        mock.enqueueRaw(data: payload, statusCode: 200)

        let (data, contentType) = try await client.blobs.download(hash: "abc")

        #expect(data == payload)
        #expect(contentType == "application/json")
    }
}
