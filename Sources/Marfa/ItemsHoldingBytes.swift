import CryptoKit
import Darwin
import Foundation

/// An item the key can list that holds the file's bytes.
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

/// A file's matching items or the reason the file was skipped.
public enum FileMatch: Sendable, Hashable {
    /// The file's SHA-256 and the items the key may list that hold those bytes.
    ///
    /// `hash` is `sha256:` followed by 64 lowercase hexadecimal digits. `items` is empty when none of the items
    /// the key can list hold the bytes. When more than 20 items match, `more` is true and `items` contains the
    /// first 20 by item ID.
    case held(hash: String, items: [FileHolder], more: Bool)
    /// The file could not be read, so its bytes were not hashed.
    case unreadable
    /// The path is not a regular file, so its bytes were not hashed.
    ///
    /// Examples include directories, symbolic links, devices, and streams.
    case notAFile
}

extension Server {
    /// The items that hold each file's bytes, in the order of `files`.
    ///
    /// Pass the URLs your app will upload. If it uploads the target of a symbolic link or Finder alias, pass the
    /// resolved URL. Passing a Finder alias directly hashes the alias file's bytes. Keep security-scoped access
    /// open for the duration of the call when a URL requires it.
    ///
    /// The method hashes regular files in pieces off the main actor and sends up to 200 hashes per request.
    /// `timeout` applies to each request. Files marked ``FileMatch/unreadable`` or ``FileMatch/notAFile`` are
    /// excluded from the request. A failed lookup throws. A canceled task stops hashing and skips remaining requests.
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
        let page = FileDigest.holderPage
        guard wire.data.allSatisfy({ $0.items.count <= page && !($0.more && $0.items.count < page) }) else {
            throw .decoding(message: "\(origin) answered a hash with a holder list its more does not match")
        }
        return wire.data
    }
}

/// SHA-256 of a file, and the request size `POST /items/blobs` accepts.
enum FileDigest {
    static let chunkBytes = 1 << 20
    /// `POST /items/blobs` answers at most this many items for one hash (`items/blobs-list`).
    static let holderPage = 20
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
        guard case .descriptor(let fd) = openForDigest(file) else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(fd) }
        return try sha256(descriptor: fd, chunkBytes: size)
    }

    static func sha256(descriptor fd: Int32, chunkBytes size: Int = chunkBytes) throws -> String {
        try sha256 {
            try readChunk(fd, size)
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
    switch openForDigest(file) {
    case .unreadable: return .unreadable
    case .notAFile: return .notAFile
    case .descriptor(let fd):
        defer { Darwin.close(fd) }
        do {
            return .hashed(try FileDigest.sha256(descriptor: fd))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }
    }
}

private enum OpenedFile {
    case descriptor(Int32)
    case unreadable
    case notAFile
}

private func openForDigest(_ file: URL) -> OpenedFile {
    // One open names the file: O_NOFOLLOW refuses a link, and O_NONBLOCK so a fifo does not wait.
    file.withUnsafeFileSystemRepresentation { path in
        guard let path else { return .unreadable }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { return errno == ELOOP ? .notAFile : .unreadable }
        guard let info = status(fd) else {
            Darwin.close(fd)
            return .unreadable
        }
        guard isRegularFile(info) else {
            Darwin.close(fd)
            return .notAFile
        }
        guard clearNonblock(fd) else {
            Darwin.close(fd)
            return .unreadable
        }
        return .descriptor(fd)
    }
}

private func status(_ fd: Int32) -> stat? {
    var info = stat()
    guard fstat(fd, &info) == 0 else { return nil }
    return info
}

private func isRegularFile(_ info: stat) -> Bool {
    info.st_mode & S_IFMT == S_IFREG
}

private func clearNonblock(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { return false }
    if flags & O_NONBLOCK == 0 { return true }
    return fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) >= 0
}

private func readChunk(_ fd: Int32, _ size: Int) throws -> Data? {
    guard size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    while true {
        let (count, error) = buffer.withUnsafeMutableBytes { raw -> (Int, Int32) in
            guard let base = raw.baseAddress else { return (-1, EINVAL) }
            let read = Darwin.read(fd, base, raw.count)
            return (read, errno)
        }
        if count > 0 { return Data(buffer[..<count]) }
        if count == 0 { return nil }
        if error != EINTR { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        try Task.checkCancellation()
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
            // The wire format requires the key even when the item has no title.
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
