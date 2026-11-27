import CryptoKit
import Foundation

/// An item the key may list whose `blob_ref` is a file's bytes.
public struct FileHolder: Sendable, Hashable {
    public let id: String
    public let type: String
    /// The item's title, when the item has one.
    public let title: String?

    public init(id: String, type: String, title: String?) {
        self.id = id
        self.type = type
        self.title = title
    }
}

/// One local file and the items that hold its bytes, or why that file was not asked about.
public enum FileMatch: Sendable, Hashable {
    /// The file's SHA-256 and the items the key may list that hold those bytes.
    ///
    /// `hash` is `sha256:` and 64 lowercase hexadecimal digits. An empty `items` is the server's answer for a hash
    /// it was asked, including when the only items that hold the bytes are ones the key may not list. `more` is
    /// true when that list stopped at 20.
    case held(hash: String, items: [FileHolder], more: Bool)
    /// The file could not be read, so its bytes were not hashed.
    case unreadable
    /// The path is not a regular file, so its bytes were not hashed.
    ///
    /// A directory, a symbolic link, a device or a stream is this. A symbolic link is not followed.
    case notAFile
}

extension Server {
    /// The items that hold each file's bytes, in the order of `files`.
    ///
    /// Each regular file is hashed in pieces, off the main actor. The hashes go in one `POST /items/blobs`, or in
    /// several of 200 when there are more, and each of those requests gets `timeout`. A file that cannot be read,
    /// or that is not a regular file, is ``FileMatch/unreadable`` or ``FileMatch/notAFile`` and is left out of
    /// the request. A lookup that fails throws. An empty `items` is only an answer the server gave. A canceled
    /// task hashes no further file and sends no further request.
    public func itemsHoldingBytes(of files: [URL], timeout: Duration = Server.defaultTimeout) async throws(MarfaError)
        -> [FileMatch]
    {
        let prepared: [LocalFile]
        do {
            prepared = try await prepare(files)
        } catch is CancellationError {
            throw .canceled(message: "the lookup of files was canceled")
        } catch {
            throw .invalid(message: "a file could not be hashed")
        }

        var matches = [FileMatch?](repeating: nil, count: files.count)
        var pending: [(index: Int, hash: String)] = []
        for (index, file) in prepared.enumerated() {
            switch file {
            case .unreadable: matches[index] = .unreadable
            case .notAFile: matches[index] = .notAFile
            case .hashed(let hash): pending.append((index, hash))
            }
        }

        var offset = 0
        while offset < pending.count {
            if Task.isCancelled { throw .canceled(message: "the lookup of files was canceled") }
            let end = min(offset + FileDigest.lookupLimit, pending.count)
            let batch = Array(pending[offset..<end])
            let entries = try await lookup(batch.map(\.hash), timeout: timeout)
            for (asked, entry) in zip(batch, entries) {
                matches[asked.index] = .held(
                    hash: entry.hash,
                    items: entry.items.map { FileHolder(id: $0.id, type: $0.type, title: $0.title) },
                    more: entry.more)
            }
            offset = end
        }
        var ordered: [FileMatch] = []
        ordered.reserveCapacity(matches.count)
        for match in matches {
            guard let match else { throw .invalid(message: "a file was left out of the lookup") }
            ordered.append(match)
        }
        return ordered
    }

    private func lookup(_ hashes: [String], timeout: Duration) async throws(MarfaError) -> [BlobLookupWire.Entry] {
        guard let body = try? JSONSerialization.data(withJSONObject: ["hashes": hashes]) else {
            throw .invalid(message: "the hashes could not be written as json")
        }
        let wire: BlobLookupWire = try decode(try await send("POST", "/items/blobs", body: body, timeout: timeout))
        guard wire.data.count == hashes.count, zip(hashes, wire.data).allSatisfy({ $0.0 == $0.1.hash }) else {
            throw .decoding(message: "\(origin) answered hashes that are not the ones asked, in that order")
        }
        return wire.data
    }
}

/// SHA-256 of a file, and the request size `POST /items/blobs` accepts.
enum FileDigest {
    /// A read is at most this many bytes, so a file is never held whole.
    static let chunkBytes = 1 << 20
    /// `POST /items/blobs` refuses a list longer than this (`items/blobs-limits`).
    static let lookupLimit = 200

    /// Runs `work` off the main actor, and cancels it when the caller is canceled.
    ///
    /// A detached task keeps running after its caller is canceled, so the cancellation is passed on.
    static func offMainActor<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func sha256(of file: URL, chunkBytes size: Int = chunkBytes) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try sha256 {
            try handle.read(upToCount: size)
        }
    }

    static func sha256(reading next: () throws -> Data?) throws -> String {
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try next(), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum LocalFile: Sendable {
    case unreadable
    case notAFile
    case hashed(String)
}

private func prepare(_ files: [URL]) async throws -> [LocalFile] {
    try await FileDigest.offMainActor {
        var prepared: [LocalFile] = []
        prepared.reserveCapacity(files.count)
        for file in files { prepared.append(try classify(file)) }
        return prepared
    }
}

private func classify(_ file: URL) throws -> LocalFile {
    try Task.checkCancellation()
    let regular: Bool
    do {
        regular = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return .unreadable
    }
    guard regular else { return .notAFile }
    do {
        return .hashed(try FileDigest.sha256(of: file))
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return .unreadable
    }
}

private struct BlobLookupWire: Decodable {
    struct Item: Decodable {
        let id: String
        let type: String
        let title: String?

        private enum Key: String, CodingKey {
            case id, type, title
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            id = try values.decode(String.self, forKey: .id)
            type = try values.decode(String.self, forKey: .type)
            // Null is an item with no title. A missing key is not that answer.
            title = try values.decode(String?.self, forKey: .title)
        }
    }

    struct Entry: Decodable {
        let hash: String
        let items: [Item]
        let more: Bool
    }

    let data: [Entry]
}
