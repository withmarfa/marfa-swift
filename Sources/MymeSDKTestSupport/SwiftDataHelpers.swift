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

    /// Builds a pure-local ``MymeClient`` backed by a fresh in-memory
    /// ``ModelContainer`` — the recommended test-setup entry point for
    /// consumer apps.
    ///
    /// Drop-in replacement for `MymeClient.local(path: <uuid>)` patterns
    /// in consumer-app test suites:
    ///
    ///     // Before:
    ///     let client = try await MymeClient.local(
    ///         path: NSTemporaryDirectory() + UUID().uuidString
    ///     )
    ///
    ///     // After:
    ///     let client = try await MymeSDKTest.makeInMemoryClient()
    ///
    /// Routing tests through this helper keeps the whole test process
    /// on in-memory SwiftData stores. That matters because XCTest host
    /// bundles can end up loading `MymeSDK.MymeItemModel` more than
    /// once (the same class name at two distinct pointers), and the
    /// persistent-store code path is where that ambiguity surfaces as
    /// `"Failed to cast model MymeSDK.MymeItemModel… to MymeItemModel"`.
    /// In-memory containers sidestep the persistent stack entirely.
    public static func makeInMemoryClient() async throws -> MymeClient {
        let container = try makeInMemoryContainer()
        return try await MymeClient.local(container: container)
    }
}
