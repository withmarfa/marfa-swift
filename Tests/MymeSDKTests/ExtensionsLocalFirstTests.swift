import Testing
import Foundation
@testable import MymeSDK
import MymeSDKTestSupport

/// Tests that ``ExtensionsNamespace`` routes through ``LocalStore`` and
/// ``MutationQueue`` in local and synced modes.
@Suite("Extensions local-first routing")
struct ExtensionsLocalFirstTests {

    // MARK: - Helpers

    private func makeStoreAndQueue() async throws -> (LocalStore, MutationQueue) {
        let (store, queue, _) = try await MymeSDKTest.makeInMemoryStorePair()
        return (store, queue)
    }

    private func makeStore() async throws -> LocalStore {
        try await MymeSDKTest.makeInMemoryLocalStore()
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
        #expect(await transport.calls.isEmpty)
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

    // MARK: - Pure-local blobs guard

    @Test("Blobs upload throws LocalModeUnsupportedError on local client") func blobsUploadThrowsOnLocalClient() async throws {
        let client = try await MymeClient.local(path: ":memory:")
        do {
            _ = try await client.blobs.upload(data: Data("hello".utf8), mimeType: "text/plain")
            Issue.record("expected LocalModeUnsupportedError")
        } catch let e as LocalModeUnsupportedError {
            #expect(e.operation == "blobs.upload")
            #expect(e.status == 501)
        }
    }

    @Test("Blobs download throws LocalModeUnsupportedError on local client") func blobsDownloadThrowsOnLocalClient() async throws {
        let client = try await MymeClient.local(path: ":memory:")
        do {
            _ = try await client.blobs.download(hash: "sha256:abc123")
            Issue.record("expected LocalModeUnsupportedError")
        } catch let e as LocalModeUnsupportedError {
            #expect(e.operation == "blobs.download")
        }
    }
}
