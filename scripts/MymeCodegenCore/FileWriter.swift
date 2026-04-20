import Foundation

public enum FileWriterError: Error, CustomStringConvertible {
    case createDirectoryFailed(URL, Error)
    case writeFailed(URL, Error)

    public var description: String {
        switch self {
        case .createDirectoryFailed(let u, let e): return "could not create directory \(u.path): \(e)"
        case .writeFailed(let u, let e): return "could not write \(u.path): \(e)"
        }
    }
}

public enum FileWriter {

    /// Writes `content` to `outputDir/name.swift`.
    public static func write(content: String, to outputDir: URL, name: String) throws -> URL {
        try ensureDirectory(outputDir)
        let url = outputDir.appendingPathComponent("\(name).swift")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw FileWriterError.writeFailed(url, error)
        }
        return url
    }

    /// Removes any `*.swift` file in `outputDir` whose base name is not in
    /// `expectedNames`. Returns the paths pruned.
    @discardableResult
    public static func prune(
        outputDir: URL,
        keeping expectedNames: Set<String>
    ) -> [URL] {
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: outputDir, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "swift" } ?? []
        var pruned: [URL] = []
        for file in existing {
            let stem = file.deletingPathExtension().lastPathComponent
            if !expectedNames.contains(stem) {
                do {
                    try FileManager.default.removeItem(at: file)
                    pruned.append(file)
                } catch {
                    // Non-fatal — just leave the file behind.
                    continue
                }
            }
        }
        return pruned
    }

    public static func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        } catch {
            throw FileWriterError.createDirectoryFailed(url, error)
        }
    }
}

/// Canonical JSON formatter for sync output. Pretty, sorted keys, LF endings —
/// so diffs of the synced snapshot are readable in review.
public enum CanonicalJSON {

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
