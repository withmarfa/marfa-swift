import Foundation
import SwiftData

extension LocalStore {
    /// Replaces the cached type graph with what the server just described.
    ///
    /// **A whole-set replacement rather than a merge**, because `GET /types`
    /// answers with the space's complete graph and a type that has been
    /// deleted upstream is absent rather than marked. Merging would keep it
    /// for ever, and a validator holding a type the space no longer has is a
    /// write accepted locally and refused on drain — the failure this cache
    /// exists to remove, reached from the other side.
    ///
    /// Rows are matched by id so a type that has not changed keeps its row,
    /// which keeps the store's change notifications quiet for the common case
    /// where a refresh finds nothing new.
    func replaceCachedTypes(with schemas: [TypeSchema]) throws {
        let stamped = now()
        let incoming = Dictionary(schemas.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        let existing = try modelContext.fetch(FetchDescriptor<CachedTypeModel>())
        var byId: [String: CachedTypeModel] = [:]
        for row in existing {
            if incoming[row.id] == nil {
                modelContext.delete(row)
            } else {
                byId[row.id] = row
            }
        }

        let encoder = JSONEncoder()
        for (id, schema) in incoming {
            let row = byId[id] ?? {
                let fresh = CachedTypeModel()
                modelContext.insert(fresh)
                return fresh
            }()
            row.id = id
            row.parent = schema.parent
            row.schemaVersion = schema.version
            row.cachedAt = stamped
            // Stored whole rather than decomposed: a field this build does not
            // know about survives the round trip and reaches one that does.
            if let data = try? encoder.encode(schema), let json = String(data: data, encoding: .utf8) {
                row.definitionJson = json
            }
        }
        try modelContext.save()
    }

    /// The cached type graph, decoded, keyed by id.
    ///
    /// A row that will not decode is skipped rather than throwing: it was
    /// written by some build, and one unreadable type should not take the
    /// whole graph — and with it every local validation — down with it.
    func cachedTypeDefinitions() throws -> [String: MarfaTypeDefinition] {
        let rows = try modelContext.fetch(FetchDescriptor<CachedTypeModel>())
        let decoder = JSONDecoder()
        var definitions: [String: MarfaTypeDefinition] = [:]
        for row in rows {
            guard let data = row.definitionJson.data(using: .utf8),
                  let schema = try? decoder.decode(TypeSchema.self, from: data)
            else { continue }
            definitions[row.id] = MarfaTypeDefinition(wire: schema)
        }
        return definitions
    }

    /// When the cache was last written, or `nil` if it never has been.
    ///
    /// What decides whether a schema refusal gets one refresh before it is
    /// treated as permanent: a cache that has never been filled is not stale,
    /// it is absent, and the two want different responses.
    func cachedTypesLastWrittenAt() throws -> String? {
        var descriptor = FetchDescriptor<CachedTypeModel>(
            sortBy: [SortDescriptor(\.cachedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.cachedAt
    }
}
