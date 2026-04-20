import Foundation
import Testing
@testable import MymeCodegenCore

@Suite struct SyncTests {

    // MARK: - Fake fetcher

    final class FakeFetcher: HTTPFetcher, @unchecked Sendable {
        var statusCode: Int = 200
        var responseBody: Data = Data()
        var recordedRequests: [(URL, [String: String])] = []
        var errorToThrow: (any Error)?

        func get(url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
            recordedRequests.append((url, headers))
            if let err = errorToThrow { throw err }
            return (
                responseBody,
                HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
    }

    // MARK: - Helpers

    func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func basicResponse(_ types: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: types)
    }

    func liveConfig(cacheDir: String = "MymeTypes") -> CodegenConfig {
        CodegenConfig(
            schema: 1,
            source: SourceConfig(mode: .live, cacheDirectory: cacheDir),
            output: OutputConfig(directory: "Generated", accessLevel: .public),
            types: TypeFilters(include: ["myapp.*"], exclude: nil)
        )
    }

    // MARK: - Tests

    @Test func syncFiltersCoreAndPersistsCustomTypes() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fetcher = FakeFetcher()
        fetcher.responseBody = basicResponse([
            ["id": "core.note", "version": 1, "fields": ["body": ["type": "string"]]],
            ["id": "myapp.booking", "version": 1, "fields": ["start_at": ["type": "string"]], "required": ["start_at"]],
            ["id": "myapp.user", "version": 1, "fields": ["name": ["type": "string"]]],
        ])

        let runner = SyncRunner(
            config: liveConfig(),
            configDir: root,
            apiURL: URL(string: "https://example.invalid/")!,
            apiKey: "test-key",
            fetcher: fetcher,
            runGenerate: false
        )
        let result = try await runner.run()

        #expect(result.written.sorted() == ["myapp.booking", "myapp.user"])
        let cacheDir = root.appendingPathComponent("MymeTypes")
        let files = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).sorted()
        #expect(files == ["myapp.booking.json", "myapp.user.json"])

        // Request carried Authorization header
        #expect(fetcher.recordedRequests.count == 1)
        let auth = fetcher.recordedRequests[0].1["Authorization"]
        #expect(auth == "Bearer test-key")
        #expect(fetcher.recordedRequests[0].0.path.hasSuffix("/types"))
    }

    @Test func syncPrunesStaleCacheFiles() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDir = root.appendingPathComponent("MymeTypes")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // Seed a stale file
        try "{}".write(
            to: cacheDir.appendingPathComponent("myapp.deleted.json"),
            atomically: true, encoding: .utf8
        )

        let fetcher = FakeFetcher()
        fetcher.responseBody = basicResponse([
            ["id": "myapp.keep", "version": 1, "fields": ["x": ["type": "string"]]],
        ])

        let runner = SyncRunner(
            config: liveConfig(),
            configDir: root,
            apiURL: URL(string: "https://example.invalid/")!,
            apiKey: "k",
            fetcher: fetcher,
            runGenerate: false
        )
        let result = try await runner.run()
        #expect(result.written == ["myapp.keep"])
        #expect(result.pruned.map { $0.lastPathComponent } == ["myapp.deleted.json"])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path).sorted()
        #expect(remaining == ["myapp.keep.json"])
    }

    @Test func nonSuccessStatusThrows() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fetcher = FakeFetcher()
        fetcher.statusCode = 401
        fetcher.responseBody = Data("unauthorized".utf8)

        let runner = SyncRunner(
            config: liveConfig(),
            configDir: root,
            apiURL: URL(string: "https://example.invalid/")!,
            apiKey: "bad",
            fetcher: fetcher,
            runGenerate: false
        )

        await #expect(throws: SyncError.self) {
            _ = try await runner.run()
        }
    }

    @Test func nonJSONResponseThrows() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fetcher = FakeFetcher()
        fetcher.responseBody = Data("<html>not json</html>".utf8)

        let runner = SyncRunner(
            config: liveConfig(),
            configDir: root,
            apiURL: URL(string: "https://example.invalid/")!,
            apiKey: "k",
            fetcher: fetcher,
            runGenerate: false
        )
        await #expect(throws: (any Error).self) {
            _ = try await runner.run()
        }
    }

    @Test func transportErrorPropagates() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        struct DummyNetErr: Error {}
        let fetcher = FakeFetcher()
        fetcher.errorToThrow = DummyNetErr()

        let runner = SyncRunner(
            config: liveConfig(),
            configDir: root,
            apiURL: URL(string: "https://example.invalid/")!,
            apiKey: "k",
            fetcher: fetcher,
            runGenerate: false
        )
        await #expect(throws: DummyNetErr.self) {
            _ = try await runner.run()
        }
    }

    @Test func syncThenGenerateEmitsSwiftFiles() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fetcher = FakeFetcher()
        fetcher.responseBody = basicResponse([
            [
                "id": "myapp.booking",
                "version": 1,
                "parent": "core.note",
                "fields": [
                    "start_at": ["type": "string", "description": "Start"],
                ],
                "required": ["start_at"],
            ]
        ])

        let runner = SyncRunner(
            config: liveConfig(),
            configDir: root,
            apiURL: URL(string: "https://example.invalid/")!,
            apiKey: "k",
            fetcher: fetcher,
            runGenerate: true
        )
        let result = try await runner.run()

        #expect(result.written == ["myapp.booking"])
        #expect(result.generated != nil)
        let genCount = result.generated?.generated.count ?? 0
        #expect(genCount == 1)

        let genDir = root.appendingPathComponent("Generated")
        let files = (try FileManager.default.contentsOfDirectory(atPath: genDir.path)).sorted()
        #expect(files == ["MyappBooking.swift"])
    }
}
