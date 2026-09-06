import Foundation

/// Metadata API namespace. Manages tags, about references, and metadata operations.
public struct MetadataNamespace: Sendable {

    let transport: any Transport
    let localStore: LocalStore?
    let mutationQueue: MutationQueue?

    /// Gets metadata for an item.
    public func get(itemId: String) async throws -> Metadata {
        if let store = localStore {
            return try await store.fetchMetadata(itemId: itemId)
        }
        let response: MetadataResponse = try await transport.request(
            method: .get, path: "/items/\(itemId.escapedPathSegment)/metadata", body: nil, query: nil
        )
        return response.metadata
    }

    /// Replaces all metadata for an item.
    public func set(itemId: String, input: MetadataInput) async throws -> Metadata {
        if let store = localStore {
            let metadata = try await store.setMetadata(itemId: itemId, input: input)
            try await mutationQueue?.enqueueSetMetadata(itemId: itemId, input: input)
            return metadata
        }
        let response: MetadataResponse = try await transport.request(
            method: .put, path: "/items/\(itemId.escapedPathSegment)/metadata", body: input, query: nil
        )
        return response.metadata
    }

    /// Merges metadata with existing values (set union for tags and about).
    public func merge(itemId: String, input: MetadataInput) async throws -> Metadata {
        if let store = localStore {
            let metadata = try await store.mergeMetadata(itemId: itemId, input: input)
            try await mutationQueue?.enqueueMergeMetadata(itemId: itemId, input: input)
            return metadata
        }
        let response: MetadataResponse = try await transport.request(
            method: .patch, path: "/items/\(itemId.escapedPathSegment)/metadata", body: input, query: nil
        )
        return response.metadata
    }

    /// Adds tags to an item.
    public func addTags(itemId: String, tags: [String]) async throws -> Metadata {
        if let store = localStore {
            let metadata = try await store.addTags(itemId: itemId, tags: tags)
            try await mutationQueue?.enqueueAddTags(itemId: itemId, tags: tags)
            return metadata
        }
        let response: MetadataResponse = try await transport.request(
            method: .post, path: "/items/\(itemId.escapedPathSegment)/tags",
            body: AddTagsBody(tags: tags), query: nil
        )
        return response.metadata
    }

    /// Enumerate the distinct set of tags in use, with per-tag counts,
    /// sorted by count desc then tag asc. Excludes trashed items.
    ///
    /// Dispatches per client mode:
    /// - **Synced / pure-local** — aggregates from the local store. No
    ///   network round-trip. An empty local store returns `[]`; synced
    ///   mode does not fall back to the network, matching the
    ///   eventual-consistency contract of every other synced read.
    /// - **Remote-only** — hits `GET /metadata/tags`. Space-scoped and
    ///   type-permission scoped server-side.
    ///
    /// In synced mode type-permission scoping is enforced naturally:
    /// the local store only contains items the caller's key synced.
    public func listTags() async throws -> [TagWithCount] {
        if let store = localStore {
            return try await store.listTags()
        }
        let response: TagListResponse = try await transport.request(
            method: .get, path: "/metadata/tags", body: nil, query: nil
        )
        return response.tags
    }

    /// Removes a single tag from an item.
    public func removeTag(itemId: String, tag: String) async throws {
        if let store = localStore {
            try await store.removeTag(itemId: itemId, tag: tag)
            try await mutationQueue?.enqueueRemoveTag(itemId: itemId, tag: tag)
            return
        }
        let _: EmptyResponse = try await transport.request(
            method: .delete,
            path: "/items/\(itemId.escapedPathSegment)/tags/\(tag.escapedPathSegment)",
            body: nil, query: nil
        )
    }
}
