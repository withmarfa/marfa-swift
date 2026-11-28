import CryptoKit
import Darwin
import Foundation
import MarfaTypes
import Synchronization
import Testing

@testable import Marfa

private let emptyHash = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
private let abcHash = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

private func thrown(_ call: () async throws -> some Any) async -> MarfaError? {
    do {
        _ = try await call()
        return nil
    } catch let error as MarfaError {
        return error
    } catch {
        return nil
    }
}

private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "holders-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ name: String, _ bytes: Data, in folder: URL) throws -> URL {
    let url = folder.appending(path: name)
    try bytes.write(to: url)
    return url
}

private func holders(count: Int, hash: String, items: String = "[]", more: Bool = false) -> String {
    let entry = #"{"hash":"\#(hash)","items":\#(items),"more":\#(more)}"#
    return #"{"data":[\#(Array(repeating: entry, count: count).joined(separator: ","))]}"#
}

private func holderItems(_ count: Int) -> String {
    let items = (0..<count).map { #"{"id":"item-\#($0)","type":"core.file","title":null}"# }
    return "[\(items.joined(separator: ","))]"
}

private func requestedHashes(_ raw: String) -> [String]? {
    guard let range = raw.range(of: "\r\n\r\n") else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: Data(raw[range.upperBound...].utf8)) as? [String: Any]
    else { return nil }
    return object["hashes"] as? [String]
}

private func server(
    _ answer: @escaping @Sendable (_ method: String, _ path: String) -> LocalServer.Answer
) async throws -> (LocalServer, Server) {
    let local = try await LocalServer.start(contract: marfaContractVersion, answer: answer)
    return (local, try Server(url: local.url, key: "mk_plain"))
}

private final class ChunkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var reads = 0
    private var waiting = false
    private var release = false

    func next() throws -> Data? {
        condition.lock()
        reads += 1
        let read = reads
        if read == 2 {
            waiting = true
            condition.broadcast()
            while !release { condition.wait() }
        }
        condition.unlock()
        if read == 1 { return Data("abc".utf8) }
        if read == 2 { return Data("xyz".utf8) }
        return Data("no".utf8)
    }

    func waitUntilSecondRead() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !waiting && Date() < deadline { condition.wait(until: deadline) }
        return waiting
    }

    func unblock() {
        condition.lock()
        release = true
        condition.broadcast()
        condition.unlock()
    }

    var readCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return reads
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ItemsHoldingBytes {
    @Test func aKnownVectorAndAnEmptyFileHashInSha256Form() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let abc = try write("abc.txt", Data("abc".utf8), in: folder)
        let empty = try write("empty.txt", Data(), in: folder)
        #expect(try FileDigest.sha256(of: abc, chunkBytes: 1) == abcHash)
        #expect(try FileDigest.sha256(of: empty) == emptyHash)
        var sent = false
        #expect(
            try FileDigest.sha256(reading: {
                defer { sent = true }
                return sent ? nil : Data("abc".utf8)
            }) == abcHash)
        #expect(try FileDigest.sha256(reading: { nil }) == emptyHash)
    }

    @Test func aFileLargerThanOneChunkMatchesTheDigestOfItsBytes() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var bytes = Data(count: FileDigest.chunkBytes + 3)
        bytes[0] = 1
        bytes[FileDigest.chunkBytes / 2] = 2
        bytes[bytes.count - 1] = 3
        let file = try write("large.bin", bytes, in: folder)
        var hasher = SHA256()
        hasher.update(data: bytes)
        let expected = "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(try FileDigest.sha256(of: file) == expected)

        var pieces = [Data("ab".utf8), Data("c".utf8), Data()]
        let streamed = try FileDigest.sha256 {
            pieces.isEmpty ? nil : pieces.removeFirst()
        }
        #expect(streamed == abcHash)
    }

    @Test func hashingStopsWhenTheTaskIsCanceled() async {
        let gate = ChunkGate()
        let task = Task {
            try await FileDigest.offMainActor {
                try FileDigest.sha256(reading: { try gate.next() })
            }
        }
        #expect(gate.waitUntilSecondRead())
        task.cancel()
        gate.unblock()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(gate.readCount == 2)
    }

    @Test @MainActor func hashingRunsOffTheMainActor() async throws {
        let onMain = try await FileDigest.offMainActor { Thread.isMainThread }
        #expect(onMain == false)
    }

    @Test func eachFileIsAnsweredInOrderAndOnlyRegularFilesAreAsked() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let abc = try write("abc.txt", Data("abc".utf8), in: folder)
        let link = folder.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: abc)
        let missing = folder.appending(path: "missing")
        let pipe = folder.appending(path: "pipe")
        #expect(mkfifo(pipe.path, 0o644) == 0)
        let hidden = try write("hidden.txt", Data("abc".utf8), in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hidden.path) }

        let item = #"{"id":"item-1","type":"core.file","title":"Shot"}"#
        let nullTitle = #"{"id":"item-2","type":"core.file","title":null}"#
        let (local, asked) = try await server { method, path in
            guard (method, path) == ("POST", "/items/blobs") else {
                return (500, "application/json", #"{"error":{"code":"unexpected","message":"\#(method) \#(path)"}}"#)
            }
            return (
                200, "application/json",
                holders(count: 1, hash: abcHash, items: "[\(item),\(nullTitle)]", more: false)
            )
        }
        defer { local.stop() }
        let matches = try await asked.itemsHoldingBytes(
            of: [folder, link, URL(fileURLWithPath: "/dev/null"), pipe, missing, hidden, abc])
        try #require(matches.count == 7)
        #expect(matches[0] == .notAFile && matches[1] == .notAFile && matches[2] == .notAFile)
        #expect(matches[3] == .notAFile && matches[4] == .unreadable && matches[5] == .unreadable)
        #expect(
            matches[6]
                == .held(
                    hash: abcHash,
                    items: [
                        FileHolder(id: "item-1", type: "core.file", title: "Shot"),
                        FileHolder(id: "item-2", type: "core.file", title: nil),
                    ], more: false))
        let sent = local.log.all.compactMap(requestedHashes)
        #expect(sent == [[abcHash]])
    }

    @Test func moreThan200HashesGoInSeparateRequests() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [URL] = []
        for index in 0..<(FileDigest.lookupLimit + 1) {
            files.append(try write("\(index).txt", Data(), in: folder))
        }
        let calls = Mutex(0)
        let (local, asked) = try await server { method, path in
            guard (method, path) == ("POST", "/items/blobs") else {
                return (500, "application/json", #"{"error":{"code":"unexpected","message":"\#(method) \#(path)"}}"#)
            }
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            let count = call == 1 ? FileDigest.lookupLimit : 1
            return (200, "application/json", holders(count: count, hash: emptyHash))
        }
        defer { local.stop() }
        let matches = try await asked.itemsHoldingBytes(of: files)
        #expect(matches == Array(repeating: .held(hash: emptyHash, items: [], more: false), count: files.count))
        let sent = local.log.all.compactMap(requestedHashes)
        try #require(sent.count == 2)
        #expect(sent[0].count == 200 && sent[1].count == 1)
        #expect(sent.flatMap { $0 }.allSatisfy { $0 == emptyHash })
    }

    @Test func anEmptyListAndFilesThatAreNotHashedSendNoRequest() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (local, asked) = try await server { _, _ in
            (500, "application/json", #"{"error":{"code":"internal_error","message":"no"}}"#)
        }
        defer { local.stop() }
        #expect(try await asked.itemsHoldingBytes(of: []).isEmpty)
        #expect(try await asked.itemsHoldingBytes(of: [folder]) == [.notAFile])
        #expect(local.log.all.isEmpty)
    }

    // Opening the FIFO would block with no writer, so a hang, not a slow answer, is the failure to catch.
    @Test(.timeLimit(.minutes(1))) func aLinkThatReplacesACachedFileIsNotFollowed() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cached = try write("cached.txt", Data("abc".utf8), in: folder)
        let target = try write("target.txt", Data("xyz".utf8), in: folder)
        let plain = folder.appending(path: "plain")
        try FileManager.default.createSymbolicLink(at: plain, withDestinationURL: target)
        let pipe = folder.appending(path: "pipe")
        #expect(mkfifo(pipe.path(percentEncoded: false), 0o644) == 0)
        let regular = try write("abc.txt", Data("abc".utf8), in: folder)

        #expect(try cached.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
        try FileManager.default.removeItem(at: cached)
        try FileManager.default.createSymbolicLink(at: cached, withDestinationURL: target)
        #expect(try cached.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)

        let (local, asked) = try await server { method, path in
            guard (method, path) == ("POST", "/items/blobs") else {
                return (500, "application/json", #"{"error":{"code":"unexpected","message":"\#(method) \#(path)"}}"#)
            }
            return (200, "application/json", holders(count: 1, hash: abcHash))
        }
        defer { local.stop() }
        let matches = try await asked.itemsHoldingBytes(of: [regular, plain, cached, pipe, folder])
        #expect(
            matches
                == [
                    .held(hash: abcHash, items: [], more: false),
                    .notAFile, .notAFile, .notAFile, .notAFile,
                ])
        #expect(local.log.all.compactMap(requestedHashes) == [[abcHash]])
    }

    @Test func aLookupFailureThrowsAndAnEmptyAnswerDoesNot() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("abc.txt", Data("abc".utf8), in: folder)
        let refused = Mutex(true)
        let (local, asked) = try await server { method, path in
            guard (method, path) == ("POST", "/items/blobs") else {
                return (500, "application/json", #"{"error":{"code":"unexpected","message":"\#(method) \#(path)"}}"#)
            }
            let failing = refused.withLock { value -> Bool in
                let failing = value
                value = false
                return failing
            }
            if failing {
                return (500, "application/json", #"{"error":{"code":"internal_error","message":"no"}}"#)
            }
            return (200, "application/json", holders(count: 1, hash: abcHash))
        }
        defer { local.stop() }
        let error = await thrown { try await asked.itemsHoldingBytes(of: [file]) }
        guard case .server(let status, let code, _, _, _) = error else {
            Issue.record("the lookup failure was \(String(describing: error))")
            return
        }
        #expect(status == 500 && code == "internal_error")
        #expect(local.log.all.count == 1)
        let matches = try await asked.itemsHoldingBytes(of: [file])
        #expect(matches == [.held(hash: abcHash, items: [], more: false)])
    }

    @Test func aSecondBatchThatFailsThrowsRatherThanReportingTheRestUnmatched() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [URL] = []
        for index in 0..<(FileDigest.lookupLimit + 1) {
            files.append(try write("\(index).txt", Data(), in: folder))
        }
        let calls = Mutex(0)
        let (local, asked) = try await server { method, path in
            guard (method, path) == ("POST", "/items/blobs") else {
                return (500, "application/json", #"{"error":{"code":"unexpected","message":"\#(method) \#(path)"}}"#)
            }
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            if call == 1 {
                return (200, "application/json", holders(count: FileDigest.lookupLimit, hash: emptyHash))
            }
            return (500, "application/json", #"{"error":{"code":"internal_error","message":"no"}}"#)
        }
        defer { local.stop() }
        let error = await thrown { try await asked.itemsHoldingBytes(of: files) }
        guard case .server = error else {
            Issue.record("the second batch was \(String(describing: error))")
            return
        }
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func anAnswerThatIsNotTheHashesAskedThrows() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("abc.txt", Data("abc".utf8), in: folder)
        let bodies = [
            #"{"data":[]}"#,
            holders(count: 1, hash: emptyHash),
            #"{"data":[{"hash":"\#(abcHash)","items":[],"more":false},{"hash":"\#(abcHash)","items":[],"more":false}]}"#,
            #"{"data":[{"hash":"\#(abcHash)","items":[{"id":"item-1","type":"core.file"}],"more":false}]}"#,
        ]
        let index = Mutex(0)
        let (local, asked) = try await server { _, _ in
            let cursor = index.withLock { value -> Int in
                let cursor = value
                value += 1
                return cursor
            }
            return (200, "application/json", bodies[cursor])
        }
        defer { local.stop() }
        for _ in bodies {
            let error = await thrown { try await asked.itemsHoldingBytes(of: [file]) }
            guard case .decoding = error else {
                Issue.record("the bad answer was \(String(describing: error))")
                return
            }
        }
    }

    @Test func anAnswerWithTooManyHoldersOrMoreSetEarlyThrows() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try write("abc.txt", Data("abc".utf8), in: folder)
        let rejected = [
            holders(count: 1, hash: abcHash, items: holderItems(0), more: true),
            holders(count: 1, hash: abcHash, items: holderItems(2), more: true),
            holders(count: 1, hash: abcHash, items: holderItems(19), more: true),
            holders(count: 1, hash: abcHash, items: holderItems(21), more: false),
            holders(count: 1, hash: abcHash, items: holderItems(21), more: true),
        ]
        let accepted = [
            holders(count: 1, hash: abcHash, items: holderItems(20), more: true),
            holders(count: 1, hash: abcHash, items: holderItems(20), more: false),
            holders(count: 1, hash: abcHash, items: holderItems(19), more: false),
        ]
        let bodies = rejected + accepted
        let index = Mutex(0)
        let (local, asked) = try await server { _, _ in
            let cursor = index.withLock { value -> Int in
                let cursor = value
                value += 1
                return cursor
            }
            return (200, "application/json", bodies[cursor])
        }
        defer { local.stop() }
        for _ in rejected {
            let error = await thrown { try await asked.itemsHoldingBytes(of: [file]) }
            guard case .decoding = error else {
                Issue.record("the holder list was \(String(describing: error))")
                return
            }
        }
        let full = try await asked.itemsHoldingBytes(of: [file])
        guard case .held(_, let fullItems, true) = full.first else {
            Issue.record("twenty holders with more were \(full)")
            return
        }
        #expect(fullItems.count == 20 && fullItems.first?.id == "item-0" && fullItems.last?.id == "item-19")
        let exact = try await asked.itemsHoldingBytes(of: [file])
        guard case .held(_, let exactItems, false) = exact.first else {
            Issue.record("twenty holders were \(exact)")
            return
        }
        #expect(exactItems.count == 20)
        let short = try await asked.itemsHoldingBytes(of: [file])
        guard case .held(_, let shortItems, false) = short.first else {
            Issue.record("nineteen holders were \(short)")
            return
        }
        #expect(shortItems.count == 19)
    }

    @Test func appsCanBuildTheValuesForPreviews() {
        let held = FileMatch.held(
            hash: abcHash, items: [FileHolder(id: "item-1", type: "core.file", title: nil)], more: false)
        #expect(held == .held(hash: abcHash, items: [.init(id: "item-1", type: "core.file", title: nil)], more: false))
        #expect(FileMatch.unreadable == .unreadable && FileMatch.notAFile == .notAFile)
    }
}

extension LiveWorkingCopies {
    @Suite(
        .enabled(if: Live.server != nil, "set MARFA_API_URL and MARFA_API_KEY to run against a server"),
        .timeLimit(.minutes(2)))
    struct LiveItemsHoldingBytes {
        private func request(
            _ method: String, _ path: String, body: Data? = nil, type: String = "application/json",
            server: Server
        ) async throws -> (status: Int, json: [String: Any]) {
            var request = URLRequest(url: server.url.appending(path: path))
            request.httpMethod = method
            request.setValue("Bearer \(server.key)", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue(type, forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = try #require((response as? HTTPURLResponse)?.statusCode)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return (status, json)
        }

        @Test func aFileItemIsFoundAndAKeyThatCannotReadItIsAnsweredAsNoMatch() async throws {
            let owner = try #require(Live.server)
            let folder = try directory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let text = "already held \(UUID().uuidString)"
            let file = try write("held.txt", Data(text.utf8), in: folder)
            let other = try write("other.txt", Data("different \(UUID().uuidString)".utf8), in: folder)
            let uploaded = try await request(
                "POST", "blobs", body: Data(text.utf8), type: "application/octet-stream", server: owner)
            try #require((200..<300).contains(uploaded.status), "upload answered \(uploaded.status) \(uploaded.json)")
            let hash = try #require(uploaded.json["hash"] as? String)
            let title = "Held \(UUID().uuidString)"
            let created = try await request(
                "POST", "items",
                body: try JSONSerialization.data(
                    withJSONObject: [
                        "type": "core.file",
                        "properties": ["title": title, "blob_ref": hash, "mime_type": "text/plain"],
                    ]), server: owner)
            try #require((200..<300).contains(created.status), "create answered \(created.status) \(created.json)")
            let item = try #require(created.json["item"] as? [String: Any])
            let id = try #require(item["id"] as? String)

            let found = try await owner.itemsHoldingBytes(of: [file, other])
            try #require(found.count == 2)
            #expect(
                found[0]
                    == .held(hash: hash, items: [FileHolder(id: id, type: "core.file", title: title)], more: false))
            guard case .held(let otherHash, let others, let more) = found[1] else {
                Issue.record("the other file was \(found)")
                return
            }
            #expect(others.isEmpty && more == false && otherHash != hash)

            let suffix = UUID().uuidString.lowercased()
            let minted = try await request(
                "POST", "keys",
                body: try JSONSerialization.data(
                    withJSONObject: [
                        "label": "Swift file holders", "source": "swift-holders-\(suffix)",
                        "default_tier": "library", "type_permissions": ["core.note": "read"],
                    ]), server: owner)
            try #require((200..<300).contains(minted.status), "mint answered \(minted.status) \(minted.json)")
            let narrowed = try Server(url: owner.url, key: try #require(minted.json["key"] as? String))
            let hidden = try await narrowed.itemsHoldingBytes(of: [file])
            #expect(hidden == [.held(hash: hash, items: [], more: false)])
        }
    }
}
