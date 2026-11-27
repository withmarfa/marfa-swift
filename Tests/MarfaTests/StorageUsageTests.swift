import Foundation
import MarfaTesting
import MarfaTypes
import Testing

@testable import Marfa

@Suite(.timeLimit(.minutes(1)))
struct StorageUsageTests {
    private static let contract = ["X-Marfa-Contract": String(marfaContractVersion)]
    private static let blobs = """
        {"count": 10, "total_bytes": 9007199254741088, "by_kind": {
            "image": {"count": 2, "total_bytes": 9007199254740993},
            "pdf": {"count": 1, "total_bytes": 17},
            "audio_video": {"count": 3, "total_bytes": 31},
            "other": {"count": 4, "total_bytes": 47}
        }}
        """

    @Test func readsEveryStorageFigureFromMetrics() async throws {
        let body = """
            {"blobs": \(Self.blobs), "storage": {
                "database_bytes": 4096, "wal_bytes": 8192,
                "blob_volume_free_bytes": 18014398509481985, "blob_volume_size_bytes": 36028797018963967,
                "rows": {"items": 19}
            }, "process": {"version": "unknown"}}
            """
        let scripted = ScriptedAuthServer { _ in Self.reply(body) }
        let usage = try await Self.server(scripted).storageUsage()
        #expect(usage.files == .init(count: 10, bytes: 9_007_199_254_741_088))
        #expect(usage.filesByKind.pictures == .init(count: 2, bytes: 9_007_199_254_740_993))
        #expect(usage.filesByKind.pdfs == .init(count: 1, bytes: 17))
        #expect(usage.filesByKind.audioAndVideo == .init(count: 3, bytes: 31))
        #expect(usage.filesByKind.other == .init(count: 4, bytes: 47))
        #expect(usage.filesByKind.inDisplayOrder.map(\.count) == [2, 1, 3, 4])
        #expect(usage.databaseBytes == 4096 && usage.writeAheadLogBytes == 8192)
        #expect(usage.freeBytes == 18_014_398_509_481_985 && usage.diskSizeBytes == 36_028_797_018_963_967)

        let request = try #require(scripted.requests(to: "/metrics").first)
        #expect(request.method == "GET")
        #expect(request.headers["Authorization"] == "Bearer at-1")
        #expect(scripted.requests.count == 1)
    }

    @Test func unreadableStorageFiguresAreNil() async throws {
        let body = """
            {"blobs": \(Self.blobs), "storage": {
                "database_bytes": null, "wal_bytes": null,
                "blob_volume_free_bytes": null, "blob_volume_size_bytes": null
            }}
            """
        let scripted = ScriptedAuthServer { _ in Self.reply(body) }
        let usage = try await Self.server(scripted).storageUsage()
        #expect(usage.databaseBytes == nil && usage.writeAheadLogBytes == nil)
        #expect(usage.freeBytes == nil && usage.diskSizeBytes == nil)
    }

    @Test func missingFileBreakdownThrowsADecodingError() async throws {
        let body = """
            {"blobs": {"count": 10, "total_bytes": 100}, "storage": {
                "database_bytes": 4096, "wal_bytes": 8192, "rows": {"items": 19}
            }}
            """
        let scripted = ScriptedAuthServer { _ in Self.reply(body) }
        let server = try Self.server(scripted)
        let error = await #expect(throws: MarfaError.self) { try await server.storageUsage() }
        guard case .decoding? = error else {
            Issue.record("expected decoding, got \(String(describing: error))")
            return
        }
    }

    @Test func aServerRefusalIsThrownAsForbidden() async throws {
        let scripted = ScriptedAuthServer { _ in
            .json(
                403, ["error": ["code": "forbidden", "message": "instance.read is required"]],
                headers: Self.contract)
        }
        let server = try Self.server(scripted, scopes: [])
        let error = await #expect(throws: MarfaError.self) { try await server.storageUsage() }
        guard case .forbidden(let code, _, _)? = error else {
            Issue.record("expected forbidden, got \(String(describing: error))")
            return
        }
        #expect(code == "forbidden")
        #expect(scripted.requests(to: "/metrics").count == 1)
    }

    @Test(
        "Live storage usage requires a server that reports file kinds and volume capacity",
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"))
    func liveStorageUsageReportsMatchingTotalsAndAvailableSpace() async throws {
        let server = try #require(Live.server)
        let usage = try await server.storageUsage()
        let kinds = usage.filesByKind.inDisplayOrder
        #expect(kinds.reduce(0) { $0 + $1.count } == usage.files.count)
        #expect(kinds.reduce(0) { $0 + $1.bytes } == usage.files.bytes)
        #expect(usage.freeBytes != nil)
    }

    private static func reply(_ body: String) -> ScriptedAuthServer.Reply {
        .raw(200, Data(body.utf8), headers: contract)
    }

    private static func server(_ scripted: ScriptedAuthServer, scopes: [String] = ["instance.read"]) throws -> Server {
        let credential = try Credential.keeping(
            accessToken: "at-1", refreshToken: nil, scopes: scopes, server: scripted.url,
            keychain: MemoryKeychain().keychain, service: "com.withmarfa.marfa-swift.tests",
            session: scripted.transport().session)
        return try Server(url: scripted.url, credential: credential)
    }
}
