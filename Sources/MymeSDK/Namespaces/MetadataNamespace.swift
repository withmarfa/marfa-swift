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
            method: .get, path: "/items/\(itemId)/metadata", body: nil, query: nil
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
            method: .put, path: "/items/\(itemId)/metadata", body: input, query: nil
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
            method: .patch, path: "/items/\(itemId)/metadata", body: input, query: nil
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
            method: .post, path: "/items/\(itemId)/tags",
            body: AddTagsBody(tags: tags), query: nil
        )
        return response.metadata
    }

    /// Enumerate the distinct set of tags in use across items the caller can
    /// read. Tenant-scoped, type-permission scoped, excludes trashed items.
    /// Returns tags with usage counts, sorted by count desc then tag asc.
    ///
    /// In remote mode hits `GET /metadata/tags`. In synced / pure-local
    /// mode walks the local store; the local store does not currently
    /// have a dedicated aggregation, so this falls back to the network
    /// path when a transport is available.
    public func listTags() async throws -> [TagWithCount] {
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
        let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        let _: EmptyResponse = try await transport.request(
            method: .delete, path: "/items/\(itemId)/tags/\(encoded)", body: nil, query: nil
        )
    }
}
