import Testing
import Foundation
@testable import MarfaSDK
import MarfaSDKTestSupport

/// Tests that ``ExtensionsNamespace`` routes through ``LocalStore`` and
/// ``MutationQueue`` in local and synced modes.
@Suite("Extensions local-first routing")
struct ExtensionsLocalFirstTests {

    // MARK: - Helpers

    private func makeStoreAndQueue() async throws -> (LocalStore, MutationQueue) {
        let (store, queue, _) = try await MarfaSDKTest.makeInMemoryStorePair()
        return (store, queue)
    }

    private func makeStore() async throws -> LocalStore {
        try await MarfaSDKTest.makeInMemoryLocalStore()
    }

    private func noteInput() -> CreateItemInput {
        CreateItemInput(type: "core.note", properties: ["body": .string("x")])
    }

    // MARK: - Local store direct

    @Test("setExtension writes a single namespace") func setExtensionWritesANamespace() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())

        let data: [String: JSONValue] = ["status": .string("indexed"), "hits": .int(3)]
        _ = try await store.setExtension(itemId: item.id, namespace: "search-index", data: data)

        let round = try await store.fetchExtension(itemId: item.id, namespace: "search-index")
        #expect(round?["status"] == .string("indexed"))
        #expect(round?["hits"] == .int(3))
    }

    @Test("setExtension preserves other namespaces") func setExtensionPreservesOtherNamespaces() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())

        _ = try await store.setExtension(itemId: item.id, namespace: "a", data: ["k": .string("a1")])
        _ = try await store.setExtension(itemId: item.id, namespace: "b", data: ["k": .string("b1")])

        let all = try await store.fetchExtensions(itemId: item.id)
        #expect(all["a"]?["k"] == .string("a1"))
        #expect(all["b"]?["k"] == .string("b1"))
    }

    @Test("deleteExtension removes a namespace") func deleteExtensionRemovesNamespace() async throws {
        let store = try await makeStore()
        let item = try await store.createItem(noteInput())

        _ = try await store.setExtension(itemId: item.id, namespace: "a", data: ["k": .string("v")])
        _ = try await store.setExtension(itemId: item.id, namespace: "b", data: ["k": .string("w")])

        try await store.deleteExtension(itemId: item.id, namespace: "a")

        let all = try await store.fetchExtensions(itemId: item.id)
        #expect(all["a"] == nil)
        #expect(all["b"]?["k"] == .string("w"))
    }

    // MARK: - Namespace + queue in synced-mode shape

    @Test("ExtensionsNamespace.set writes locally and enqueues") func namespaceSetEnqueues() async throws {
        let (store, queue) = try await makeStoreAndQueue()
        let transport = MockTransport()
        let ns = ExtensionsNamespace(transport: transport, localStore: store, mutationQueue: queue)

        let item = try await store.createItem(noteInput())
        let data: [String: JSONValue] = ["foo": .string("bar")]
        _ = try await ns.set(itemId: item.id, namespace: "app", data: data)

        // Local write landed
        let local = try await store.fetchExtension(itemId: item.id, namespace: "app")
        #expect(local?["foo"] == .string("bar"))

        // Queue recorded a .setExtension
        let pending = try await queue.fetchAll()
        #expect(pending.count == 1)
        #expect(pending[0].kind == .setExtension)
        #expect(pending[0].localId == item.id)

        // Transport untouched
        #expect(transport.calls.isEmpty)
    }

    @Test("ExtensionsNamespace.delete removes locally and enqueues") func namespaceDeleteEnqueues() async throws {
        let (store, queue) = try await makeStoreAndQueue()
        let transport = MockTransport()
        let ns = ExtensionsNamespace(transport: transport, localStore: store, mutationQueue: queue)

        let item = try await store.createItem(noteInput())
        _ = try await store.setExtension(itemId: item.id, namespace: "app", data: ["foo": .string("bar")])

        try await ns.delete(itemId: item.id, namespace: "app")

        #expect(try await store.fetchExtension(itemId: item.id, namespace: "app") == nil)

        let pending = try await queue.fetchAll()
        #expect(pending.count == 1)
        #expect(pending[0].kind == .deleteExtension)
    }

    @Test("MetadataNamespace.set replaces the tags and leaves the extensions alone")
    func metadataSetLeavesExtensionsAlone() async throws {
        let (store, queue) = try await makeStoreAndQueue()
        let transport = MockTransport()
        let metadata = MetadataNamespace(transport: transport, localStore: store, mutationQueue: queue)
        let extensions = ExtensionsNamespace(transport: transport, localStore: store, mutationQueue: queue)

        let item = try await store.createItem(noteInput())
        _ = try await extensions.set(itemId: item.id, namespace: "app", data: ["foo": .string("bar")])

        _ = try await metadata.set(itemId: item.id, input: MetadataInput(tags: ["work"]))

        // `PUT /items/{id}/metadata` writes the tags column and nothing else,
        // so a synced client whose local write cleared the sidecar would
        // disagree with the server it is about to replay against.
        #expect(try await metadata.get(itemId: item.id).tags == ["work"])
        let namespace = try await extensions.get(itemId: item.id, namespace: "app")
        #expect(namespace?["foo"] == .string("bar"))
    }

    @Test("MetadataNamespace.set refuses an item the store does not hold")
    func metadataSetRefusesAnUnknownItem() async throws {
        let (store, queue) = try await makeStoreAndQueue()
        let transport = MockTransport()
        let metadata = MetadataNamespace(transport: transport, localStore: store, mutationQueue: queue)

        // The server answers 404 here, and writing anyway does not merely
        // differ from it — the row attaches to its item only as it is
        // inserted and `upsertItem` never adopts one, so the write would be
        // invisible for good the moment it succeeded.
        await #expect(throws: NotFoundError.self) {
            _ = try await metadata.set(itemId: "never-created", input: MetadataInput(tags: ["x"]))
        }
        #expect(try await queue.fetchAll().isEmpty)
    }

    @Test("MetadataNamespace.removeTag refuses an item the store does not hold")
    func metadataRemoveTagRefusesAnUnknownItem() async throws {
        let (store, queue) = try await makeStoreAndQueue()
        let transport = MockTransport()
        let metadata = MetadataNamespace(transport: transport, localStore: store, mutationQueue: queue)

        // Removing a tag from an item that is not here reads as a no-op and is
        // not one: the row is fetched empty, filtered to nothing, and then
        // written — inserting a detached row on the way out, for a call whose
        // whole purpose was to take something away.
        await #expect(throws: NotFoundError.self) {
            try await metadata.removeTag(itemId: "never-created", tag: "x")
        }
        #expect(try await queue.fetchAll().isEmpty)
    }

    // MARK: - Pure-local blobs guard

    /// **`upload` used to be in this guard and is not any more.** It refused
    /// because there was no door into the store's blob table, not because a
    /// client with no server has no business holding bytes — and the refusal
    /// left the cache able to hold only what an earlier synced session had put
    /// there. It writes now, as owned rather than cached; see `OfflineBlobTests`.
    ///
    /// The rest of the namespace still refuses, and for a reason that has not
    /// changed: `exists`, `presignedURL` and a `download` of a hash this device
    /// does not hold are all questions only a server can answer.
    @Test("Blobs upload writes to the store rather than refusing on a local client")
    func blobsUploadWritesOnLocalClient() async throws {
        let client = try await MarfaClient.local(path: ":memory:")
        let response = try await client.blobs.upload(
            data: Data("hello".utf8), mimeType: "text/plain"
        )
        #expect(response.hash.hasPrefix("sha256:"))
        #expect(response.size == 5)
    }

    @Test("Blobs exists throws LocalModeUnsupportedError on local client")
    func blobsExistsThrowsOnLocalClient() async throws {
        let client = try await MarfaClient.local(path: ":memory:")
        do {
            _ = try await client.blobs.exists(hash: "sha256:nothing")
            Issue.record("expected LocalModeUnsupportedError")
        } catch let e as LocalModeUnsupportedError {
            #expect(e.operation == "blobs.exists")
            #expect(e.status == 501)
        }
    }

    @Test("Blobs download throws LocalModeUnsupportedError on local client") func blobsDownloadThrowsOnLocalClient() async throws {
        let client = try await MarfaClient.local(path: ":memory:")
        do {
            _ = try await client.blobs.download(hash: "sha256:abc123")
            Issue.record("expected LocalModeUnsupportedError")
        } catch let e as LocalModeUnsupportedError {
            #expect(e.operation == "blobs.download")
        }
    }
}
