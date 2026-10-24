import Marfa
import MarfaTypes

/// Item and edge types, registered, changed and removed on the server.
///
/// A working copy reads the types it holds from its catalog; these calls change the server's.
extension Client {
    /// Registers an item type, and answers it as the server stored it.
    ///
    /// The type's `id` is under the credential's own namespace, such as `app.readinglist.entry`.
    public func register(itemType definition: Components.Schemas.TypeDefinitionInput) async throws
        -> Components.Schemas.RegisteredType
    {
        try await answer("registerType") { try await registerType(body: .json(definition)).created.body.json._type }
    }

    /// Replaces the definition of the item type `id`, and answers it as the server stored it.
    public func replace(itemType id: String, with definition: Components.Schemas.TypeDefinitionUpdate) async throws
        -> Components.Schemas.RegisteredType
    {
        try await answer("replaceType") {
            try await replaceType(path: .init(id: id), body: .json(definition)).ok.body.json._type
        }
    }

    /// Deletes the item type `id`.
    ///
    /// With `force`, it is deleted even while items of it exist.
    public func delete(itemType id: String, force: Bool = false) async throws {
        try await answer("deleteType") {
            _ = try await deleteType(path: .init(id: id), query: .init(force: force ? ._true : nil)).ok
        }
    }

    /// Checks a definition without registering it: the type as the server would store it, the type it would
    /// replace, and the type with what it inherits.
    public func check(itemType definition: Components.Schemas.TypeDefinitionInput) async throws
        -> Components.Schemas.NormalizedType
    {
        try await answer("normalizeType") { try await normalizeType(body: .json(definition)).ok.body.json }
    }

    /// Registers an edge type, or answers the one already registered with the same definition.
    public func register(edgeType definition: Components.Schemas.EdgeTypeRegistrationRequest) async throws
        -> Components.Schemas.EdgeType
    {
        try await answer("registerEdgeType") {
            let output = try await registerEdgeType(body: .json(definition))
            if case .created(let created) = output { return try created.body.json.edgeType }
            return try output.ok.body.json.edgeType
        }
    }

    /// Every edge type the server holds.
    public func edgeTypes() async throws -> [Components.Schemas.EdgeType] {
        try await answer("listEdgeTypes") { try await listEdgeTypes().ok.body.json.data }
    }

    /// Deletes the edge type `id`.
    ///
    /// With `force`, it is deleted even while edges of it exist; they keep naming it.
    public func delete(edgeType id: String, force: Bool = false) async throws {
        try await answer("deleteEdgeType") {
            _ = try await deleteEdgeType(path: .init(id: id), query: .init(force: force ? ._true : nil)).ok
        }
    }
}

/// Reads a success the server answered with a status the generated client did not expect as ``MarfaError``.
private func answer<T>(_ operation: String, _ read: () async throws -> T) async throws(MarfaError) -> T {
    do {
        return try await read()
    } catch let error as MarfaError {
        throw error
    } catch {
        throw .decoding(message: "the server answered \(operation) with a success this build does not read")
    }
}
