import Foundation
import SwiftData
@_spi(MarfaSDKTestSupport) import MarfaSDK

/// Test-support helpers for the SwiftData-backed local store.
///
/// Tests call into these so the actor construction path matches the
/// production one in ``MarfaClient/local(path:)`` and
/// ``MarfaClient/synced(url:apiKey:storePath:)`` — `Task.detached`
/// off-main, then bind to the actor's executor.
public enum MarfaSDKTest {

    /// Builds an in-memory ``ModelContainer`` against the current schema.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        try MarfaModelContainer.make(path: ":memory:")
    }

    /// Builds an in-memory ``LocalStore`` backed by a fresh container,
    /// constructed off the main actor (matches `MarfaClient.local(path:)`).
    public static func makeInMemoryLocalStore() async throws -> LocalStore {
        let container = try makeInMemoryContainer()
        return await Task.detached { LocalStore(modelContainer: container) }.value
    }

    /// Builds an in-memory ``LocalStore`` and a sibling ``MutationQueue``
    /// sharing one container — the same shape as `MarfaClient.synced(...)`.
    /// Sequential construction (not `async let`) — the `@ModelActor`
    /// synthesized init isn't safe against concurrent construction on
    /// the same container in current SwiftData.
    public static func makeInMemoryStorePair() async throws -> (LocalStore, MutationQueue, ModelContainer) {
        let container = try makeInMemoryContainer()
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let queue = await Task.detached { MutationQueue(modelContainer: container) }.value
        return (store, queue, container)
    }

    /// Builds a pure-local ``MarfaClient`` backed by a fresh in-memory
    /// ``ModelContainer`` — the recommended test-setup entry point for
    /// consumer apps.
    ///
    /// Drop-in replacement for `MarfaClient.local(path: <uuid>)` patterns
    /// in consumer-app test suites:
    ///
    ///     // Before:
    ///     let client = try await MarfaClient.local(
    ///         path: NSTemporaryDirectory() + UUID().uuidString
    ///     )
    ///
    ///     // After:
    ///     let client = try await MarfaSDKTest.makeInMemoryClient()
    ///
    /// Routing tests through this helper keeps the whole test process
    /// on in-memory SwiftData stores. That matters because XCTest host
    /// bundles can end up loading `MarfaSDK.MarfaItemModel` more than
    /// once (the same class name at two distinct pointers), and the
    /// persistent-store code path is where that ambiguity surfaces as
    /// `"Failed to cast model MarfaSDK.MarfaItemModel… to MarfaItemModel"`.
    /// In-memory containers sidestep the persistent stack entirely.
    public static func makeInMemoryClient() async throws -> MarfaClient {
        let container = try makeInMemoryContainer()
        return try await MarfaClient.local(container: container)
    }
}
