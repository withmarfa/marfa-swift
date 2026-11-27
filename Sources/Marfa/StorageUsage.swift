/// The server's file usage, database sizes, and file volume capacity.
public struct StorageUsage: Sendable, Hashable {
    /// The count and total size of a group of stored files.
    public struct FileUsage: Sendable, Hashable {
        /// The number of stored files.
        public let count: Int
        /// The total size in bytes.
        public let bytes: Int64

        /// Creates a file usage reading with the given count and size.
        public init(count: Int, bytes: Int64) {
            self.count = count
            self.bytes = bytes
        }
    }

    /// The usage of stored files grouped by media type.
    public struct FilesByKind: Sendable, Hashable {
        /// The usage of image files.
        public let pictures: FileUsage
        /// The usage of PDF files.
        public let pdfs: FileUsage
        /// The combined usage of audio and video files.
        public let audioAndVideo: FileUsage
        /// The usage of files outside the preceding kinds.
        public let other: FileUsage

        /// The readings for pictures, PDFs, audio and video, and other files, in that order.
        public var inDisplayOrder: [FileUsage] { [pictures, pdfs, audioAndVideo, other] }

        /// Creates a breakdown with a reading for each file kind.
        public init(pictures: FileUsage, pdfs: FileUsage, audioAndVideo: FileUsage, other: FileUsage) {
            self.pictures = pictures
            self.pdfs = pdfs
            self.audioAndVideo = audioAndVideo
            self.other = other
        }
    }

    /// The usage of all stored files.
    public let files: FileUsage
    /// The usage of stored files broken down by kind.
    public let filesByKind: FilesByKind
    /// The database file's size in bytes, or `nil` when unavailable.
    public let databaseBytes: Int64?
    /// The database's write-ahead log size in bytes, or `nil` when unavailable.
    public let writeAheadLogBytes: Int64?
    /// The available bytes on the volume that holds the files, or `nil` when unavailable.
    public let freeBytes: Int64?
    /// The total capacity in bytes of the volume that holds the files, or `nil` when unavailable.
    public let diskSizeBytes: Int64?

    /// Creates a storage reading from the file, database, and volume figures.
    public init(
        files: FileUsage, filesByKind: FilesByKind, databaseBytes: Int64?, writeAheadLogBytes: Int64?,
        freeBytes: Int64?, diskSizeBytes: Int64?
    ) {
        self.files = files
        self.filesByKind = filesByKind
        self.databaseBytes = databaseBytes
        self.writeAheadLogBytes = writeAheadLogBytes
        self.freeBytes = freeBytes
        self.diskSizeBytes = diskSizeBytes
    }
}

extension Server {
    /// Reads the instance's storage usage.
    ///
    /// Requires `instance.read`. A response without a file breakdown throws
    /// ``MarfaError/decoding(message:)``.
    public func storageUsage(timeout: Duration = Server.defaultTimeout) async throws(MarfaError) -> StorageUsage {
        let data = try await send("GET", "/metrics", timeout: timeout)
        let wire: StorageUsageWire = try decode(data)
        let byKind = wire.blobs.byKind
        return StorageUsage(
            files: .init(count: wire.blobs.count, bytes: wire.blobs.totalBytes),
            filesByKind: .init(
                pictures: byKind.image.usage, pdfs: byKind.pdf.usage, audioAndVideo: byKind.audioVideo.usage,
                other: byKind.other.usage),
            databaseBytes: wire.storage.databaseBytes, writeAheadLogBytes: wire.storage.walBytes,
            freeBytes: wire.storage.blobVolumeFreeBytes, diskSizeBytes: wire.storage.blobVolumeSizeBytes)
    }
}

private struct StorageUsageWire: Decodable {
    struct FileTotals: Decodable {
        let count: Int
        let totalBytes: Int64

        var usage: StorageUsage.FileUsage { .init(count: count, bytes: totalBytes) }

        enum CodingKeys: String, CodingKey {
            case count
            case totalBytes = "total_bytes"
        }
    }

    struct Blobs: Decodable {
        struct ByKind: Decodable {
            let image: FileTotals
            let pdf: FileTotals
            let audioVideo: FileTotals
            let other: FileTotals

            enum CodingKeys: String, CodingKey {
                case image, pdf, other
                case audioVideo = "audio_video"
            }
        }

        let count: Int
        let totalBytes: Int64
        let byKind: ByKind

        enum CodingKeys: String, CodingKey {
            case count
            case totalBytes = "total_bytes"
            case byKind = "by_kind"
        }
    }

    struct Storage: Decodable {
        let databaseBytes: Int64?
        let walBytes: Int64?
        let blobVolumeFreeBytes: Int64?
        let blobVolumeSizeBytes: Int64?

        enum CodingKeys: String, CodingKey {
            case databaseBytes = "database_bytes"
            case walBytes = "wal_bytes"
            case blobVolumeFreeBytes = "blob_volume_free_bytes"
            case blobVolumeSizeBytes = "blob_volume_size_bytes"
        }
    }

    let blobs: Blobs
    let storage: Storage
}
