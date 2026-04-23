import Foundation
import SwiftData
@_spi(MymeSDKTestSupport) import MymeSDK

/// Test-support helpers for the SwiftData-backed local store.
///
/// Tests call into these so the actor construction path matches the
/// production one in ``MymeClient/local(path:)`` and
/// ``MymeClient/synced(url:apiKey:storePath:)`` — `Task.detached`
/// off-main, then bind to the actor's executor.
public enum MymeSDKTest {

    /// Builds an in-memory ``ModelContainer`` against the v1 schema.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        try MymeModelContainer.make(path: ":memory:")
    }

    /// Builds an in-memory ``LocalStore`` backed by a fresh container,
    /// constructed off the main actor (matches `MymeClient.local(path:)`).
    public static func makeInMemoryLocalStore() async throws -> LocalStore {
        let container = try makeInMemoryContainer()
        return await Task.detached { LocalStore(modelContainer: container) }.value
    }

    /// Builds an in-memory ``MutationQueue`` against an existing container.
    public static func makeMutationQueue(in container: ModelContainer) async -> MutationQueue {
        await Task.detached { MutationQueue(modelContainer: container) }.value
    }

    /// Builds an in-memory ``LocalStore`` and a sibling ``MutationQueue``
    /// sharing one container — the same shape as `MymeClient.synced(...)`.
    /// Sequential construction (not `async let`) — the `@ModelActor`
    /// synthesised init isn't safe against concurrent construction on
    /// the same container in current SwiftData.
    public static func makeInMemoryStorePair() async throws -> (LocalStore, MutationQueue, ModelContainer) {
        let container = try makeInMemoryContainer()
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let queue = await Task.detached { MutationQueue(modelContainer: container) }.value
        return (store, queue, container)
    }

    /// Awaits the reactive debounce window plus headroom. Use after a
    /// write that should propagate to a reactive query — `MymeStoreTests`
    /// polls `query.items` after this, so the additional sleep gives
    /// the `ModelContext.didSave` notification time to fire and the
    /// debounce task time to schedule the refetch.
    @MainActor
    public static func waitForRefetch(after ms: Int = 80) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }
}
