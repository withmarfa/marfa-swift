import Foundation

public enum SchemaLoaderError: Error, CustomStringConvertible {
    case directoryMissing(URL)
    case notADirectory(URL)
    case malformedSchema(URL, Error)
    case duplicateID(id: String, files: [URL])
    case coreTypeInCustomDirectory(id: String, file: URL)

    public var description: String {
        switch self {
        case .directoryMissing(let u): return "schemas directory not found: \(u.path)"
        case .notADirectory(let u): return "schemas path is not a directory: \(u.path)"
        case .malformedSchema(let u, let e): return "could not parse schema file \(u.lastPathComponent): \(e)"
        case .duplicateID(let id, let files):
            let list = files.map { $0.lastPathComponent }.joined(separator: ", ")
            return "multiple schema files declare type id `\(id)`: \(list)"
        case .coreTypeInCustomDirectory(let id, let file):
            return "schema file \(file.lastPathComponent) declares core type id `\(id)` — `core.*` ids are reserved. Remove or rename."
        }
    }
}

public enum SchemaLoader {

    /// Reads every `.json` file in `dir` (non-recursive) as a `CodegenTypeSchema`.
    /// Returns a dict keyed by type ID.
    ///
    /// `allowCoreTypes`:
    ///   - `true` when loading the bundled SDK core registry (parent resolution).
    ///   - `false` when loading the consumer's custom schemas — a `core.*` id
    ///     in the user's directory is an error because it would collide with
    ///     SDK-shipped types.
    public static func loadSchemas(
        from dir: URL,
        allowCoreTypes: Bool = false
    ) throws -> [String: CodegenTypeSchema] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
            throw SchemaLoaderError.directoryMissing(dir)
        }
        guard isDir.boolValue else { throw SchemaLoaderError.notADirectory(dir) }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" } ?? []

        let decoder = JSONDecoder()
        var result: [String: CodegenTypeSchema] = [:]
        var sources: [String: [URL]] = [:]

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data: Data
            do { data = try Data(contentsOf: file) } catch {
                throw SchemaLoaderError.malformedSchema(file, error)
            }
            let schema: CodegenTypeSchema
            do {
                schema = try decoder.decode(CodegenTypeSchema.self, from: data)
            } catch {
                throw SchemaLoaderError.malformedSchema(file, error)
            }
            if !allowCoreTypes && (schema.id.hasPrefix("core.") || schema.id == "core") {
                throw SchemaLoaderError.coreTypeInCustomDirectory(id: schema.id, file: file)
            }
            sources[schema.id, default: []].append(file)
            result[schema.id] = schema
        }

        for (id, fs) in sources where fs.count > 1 {
            throw SchemaLoaderError.duplicateID(id: id, files: fs)
        }

        return result
    }

    /// Loads the bundled core-type snapshot. The JSON files ship as resources
    /// copied by SwiftPM from `scripts/MarfaCodegenCore/core-types/`.
    public static func loadBundledCoreTypes() throws -> [String: CodegenTypeSchema] {
        guard let url = Bundle.module.url(forResource: "core-types", withExtension: nil) else {
            // This can only happen if the resource wasn't copied by SwiftPM —
            // a packaging bug, not a user-facing condition.
            throw SchemaLoaderError.directoryMissing(
                URL(fileURLWithPath: "core-types")
            )
        }
        return try loadSchemas(from: url, allowCoreTypes: true)
    }
}
