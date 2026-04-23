import Foundation
import SwiftData

/// Client for the Myme API.
///
/// Provides namespaced access to all API endpoints:
///
///     let client = MymeClient(url: serverURL, apiKey: key)
///     let item = try await client.items.create(
///         CreateItemInput(type: "core.note", properties: ["title": "Hello"])
///     )
///     let results = try await client.search(query: "hello")
///
/// For pure offline / on-device use, create a local-only client backed
/// by a SwiftData store — no API key or server URL required:
///
///     let client = try await MymeClient.local(path: "/path/to/store.sqlite")
///     let note = try await client.items.create(
///         CreateItemInput(type: "core.note", properties: ["body": .string("Hello")])
///     )
///
/// The client is `Sendable` and safe to share across tasks and actors.
public final class MymeClient: Sendable {

    /// The underlying transport (internal for testing).
    let transport: any Transport

    /// The client configuration.
    public let configuration: ClientConfiguration

    /// Items API: create, get, list, update, delete, restore, transition, versions, stats.
    public let items: ItemsNamespace

    /// Metadata API: get, set, merge tags and about references.
    public let metadata: MetadataNamespace

    /// Extensions API: read and write namespaced extension data.
    public let extensions: ExtensionsNamespace

    /// Edges API: create, update, delete typed edges; list from source / to target.
    public let edges: EdgesNamespace

    /// Blobs API: upload, download, check existence, get URLs.
    public let blobs: BlobsNamespace

    /// Types API: list, get, register, update, delete type schemas.
    public let types: TypesNamespace

    /// Keys API: create, list, revoke API keys.
    public let keys: KeysNamespace

    /// Webhooks API: create, list, get, update, delete, delivery history.
    public let webhooks: WebhooksNamespace

    /// The active sync engine, present only in synced mode (``MymeClient/synced(url:apiKey:storePath:)``).
    ///
    /// Call ``SyncEngine/start()`` to begin synchronisation and
    /// ``SyncEngine/stop()`` to tear it down gracefully.
    public let syncEngine: SyncEngine?

    /// The underlying ``ModelContainer``, non-nil when a local store is
    /// configured. Used by ``makeStore()`` to create ``MymeStore``
    /// instances. `ModelContainer` is `Sendable` and safe to store on
    /// `MymeClient`.
    private let container: ModelContainer?

    // MARK: - Init

    /// Designated init — used by every other init path, including tests.
    init(
        configuration: ClientConfiguration,
        transport: any Transport,
        localStore: LocalStore? = nil,
        mutationQueue: MutationQueue? = nil,
        syncEngine: SyncEngine? = nil,
        container: ModelContainer? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.syncEngine = syncEngine
        self.container = container

        let items = ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: configuration.conflictStrategy,
            localStore: localStore,
            mutationQueue: mutationQueue
        )
        let edges = EdgesNamespace(
            transport: transport,
            localStore: localStore,
            mutationQueue: mutationQueue,
            maxBackrefBatchConcurrency: configuration.maxBackrefBatchConcurrency
        )
        self.items = items
        self.edges = edges
        self.metadata = MetadataNamespace(
            transport: transport,
            localStore: localStore,
            mutationQueue: mutationQueue
        )
        self.extensions = ExtensionsNamespace(
            transport: transport,
            localStore: localStore,
            mutationQueue: mutationQueue
        )
        // Pure-local mode has a local store but no sync engine — blob
        // ops can't round-trip through the server and must throw early.
        // In synced mode the mutation queue is passed so uploads are
        // queued for offline-resilient replay rather than hitting the
        // transport directly.
        self.blobs = BlobsNamespace(
            transport: transport,
            apiBaseURL: configuration.url,
            cdnBaseURL: configuration.cdnBaseURL,
            mutationQueue: syncEngine != nil ? mutationQueue : nil,
            isLocalMode: localStore != nil && syncEngine == nil
        )
        self.types = TypesNamespace(transport: transport)
        self.keys = KeysNamespace(transport: transport)
        self.webhooks = WebhooksNamespace(transport: transport)
    }

    /// Creates a client with the given configuration.
    public convenience init(configuration: ClientConfiguration) {
        self.init(
            configuration: configuration,
            transport: URLSessionTransport(configuration: configuration)
        )
    }

    /// Creates a client with a URL and API key using default settings.
    public convenience init(url: URL, apiKey: String) {
        self.init(configuration: ClientConfiguration(url: url, apiKey: apiKey))
    }

    /// Creates a pure-local client backed by a SwiftData store at `path`.
    ///
    /// No server URL or API key is required. All namespace calls
    /// resolve against the local store. Pass `":memory:"` for an
    /// ephemeral store (useful in tests).
    ///
    /// This is a convenience over ``MymeClient/local(container:)`` for
    /// callers who want the SDK to build the container for them.
    /// Consumers that need to configure the container directly — for
    /// example to enable CloudKit mirroring via
    /// `MymeModelContainer.make(path:cloudKitDatabase:)` — should build
    /// the container themselves and call ``MymeClient/local(container:)``.
    ///
    /// `async` because the underlying `LocalStore` is constructed off
    /// the main actor via `Task.detached` — `@ModelActor`'s synthesised
    /// init binds the actor's executor to whatever actor calls it, so
    /// calling from `@MainActor` would silently route every method onto
    /// the main thread.
    ///
    /// - Throws: ``LocalStoreError`` if the database cannot be opened or
    ///   migrated.
    public static func local(path: String) async throws -> MymeClient {
        let container = try MymeModelContainer.make(path: path)
        return try await local(container: container)
    }

    /// Creates a pure-local client backed by a caller-supplied
    /// ``ModelContainer``.
    ///
    /// Use this when you need to control how the container is built —
    /// for example, to enable CloudKit mirroring by passing
    /// `cloudKitDatabase: .automatic(containerIdentifier: "iCloud.…")` to
    /// ``MymeModelContainer/make(path:cloudKitDatabase:)``:
    ///
    ///     let container = try MymeModelContainer.make(
    ///         path: path,
    ///         cloudKitDatabase: .automatic(containerIdentifier: "iCloud.example.app")
    ///     )
    ///     let client = try await MymeClient.local(container: container)
    ///
    /// All namespace calls resolve against the local store; no server URL
    /// or API key is required. The transport is never invoked in
    /// pure-local mode.
    ///
    /// `async` because the underlying `LocalStore` is constructed off
    /// the main actor via `Task.detached` — `@ModelActor`'s synthesised
    /// init binds the actor's executor to whatever actor calls it, so
    /// calling from `@MainActor` would silently route every method onto
    /// the main thread.
    public static func local(container: ModelContainer) async throws -> MymeClient {
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        // The transport is never invoked in pure-local mode: every
        // namespace method checks `localStore` first before touching the
        // transport. URL is a placeholder; the fallback guards against
        // the synthetic `local://offline` scheme ever failing to parse
        // in a future SDK.
        let config = ClientConfiguration(
            url: URL(string: "local://offline") ?? URL(fileURLWithPath: "/dev/null"),
            apiKey: ""
        )
        return MymeClient(
            configuration: config,
            transport: URLSessionTransport(configuration: config),
            localStore: store,
            container: container
        )
    }

    /// Creates a synced client backed by a SwiftData store and a live
    /// server connection.
    ///
    /// The client writes optimistically to the local store on every
    /// mutation and enqueues the mutation for background replay. The
    /// returned ``SyncEngine`` (via ``MymeClient/syncEngine``) must be
    /// started by the caller:
    ///
    ///     let client = try await MymeClient.synced(url: serverURL, apiKey: key, storePath: dbPath)
    ///     await client.syncEngine?.start()
    ///
    /// - Parameters:
    ///   - url: Base URL of the Myme API.
    ///   - apiKey: API key for authentication.
    ///   - storePath: Path to the SwiftData store file. Pass `":memory:"`
    ///     for tests.
    ///   - connectionManager: Optional pre-built manager; the default
    ///     creates one.
    /// - Throws: ``LocalStoreError`` if the database cannot be opened or
    ///   migrated.
    public static func synced(
        url: URL,
        apiKey: String,
        storePath: String,
        connectionManager: ConnectionStateManager = ConnectionStateManager()
    ) async throws -> MymeClient {
        let config = ClientConfiguration(url: url, apiKey: apiKey)
        let transport = URLSessionTransport(configuration: config)
        let container = try MymeModelContainer.make(path: storePath)
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let queue = await Task.detached { MutationQueue(modelContainer: container) }.value
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connectionManager
        )
        return MymeClient(
            configuration: config,
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            syncEngine: engine,
            container: container
        )
    }

    /// Creates a client from environment variables (`MYME_API_URL`,
    /// `MYME_API_KEY`). Returns `nil` if the environment variables are
    /// not set.
    public static func fromEnvironment() -> MymeClient? {
        guard let config = ClientConfiguration.fromEnvironment() else { return nil }
        return MymeClient(configuration: config)
    }

    /// Creates a client by loading the API key from the system Keychain.
    ///
    /// - Parameters:
    ///   - service: Keychain service. Defaults to `"myme.sdk"`.
    ///   - account: Keychain account identifier (typically the server
    ///     hostname or a named environment).
    ///   - url: Base URL of the Myme API.
    ///   - accessGroup: Optional access group for app-extension sharing.
    /// - Throws: ``KeychainError`` if the item is missing or unreadable.
    public static func fromKeychain(
        service: String = "myme.sdk",
        account: String,
        url: URL,
        accessGroup: String? = nil
    ) async throws -> MymeClient {
        let storage = KeychainStorage(service: service, accessGroup: accessGroup)
        return try await fromSecureStorage(service: service, account: account, url: url, storage: storage)
    }

    /// Protocol-based helper — takes any ``SecureStorage`` so tests can
    /// pass an ``InMemoryKeychain`` without touching the real Keychain.
    public static func fromSecureStorage(
        service: String = "myme.sdk",
        account: String,
        url: URL,
        storage: any SecureStorage
    ) async throws -> MymeClient {
        guard let apiKey = try await storage.get(for: account) else {
            throw KeychainError.osStatus(errSecItemNotFound)
        }
        return MymeClient(url: url, apiKey: apiKey)
    }

    /// Writes the current client's API key back to the system Keychain.
    public func saveToKeychain(
        service: String = "myme.sdk",
        account: String,
        accessGroup: String? = nil
    ) async throws {
        let storage = KeychainStorage(service: service, accessGroup: accessGroup)
        try await storage.set(configuration.apiKey, for: account)
    }

    // MARK: - Reactive store

    /// Creates a ``MymeStore`` for use with SwiftUI and `@Observable`.
    ///
    /// Returns `nil` when the client has no local store configured (i.e.
    /// it was created with ``MymeClient/init(url:apiKey:)`` or
    /// ``MymeClient/init(configuration:)`` without a local store path).
    ///
    /// Must be called from a `@MainActor` context. Callers typically
    /// hold the returned store as a `@State` or environment object in a
    /// SwiftUI view:
    ///
    ///     @State private var store = client.makeStore()
    ///     // ...
    ///     let notes = store?.query(filters: ListFilters(type: "core.note"))
    ///
    /// Each call to `makeStore()` returns a new `MymeStore` instance
    /// backed by the same underlying ``ModelContainer`` — multiple
    /// stores observe the same data.
    @MainActor
    public func makeStore() -> MymeStore? {
        guard let container else { return nil }
        return MymeStore(container: container)
    }

    // MARK: - Top-Level Methods

    /// Full-text search across items.
    public func search(query: String, filters: SearchFilters? = nil) async throws -> [SearchResult] {
        let params = filters?.toQueryParams(query: query) ?? [("q", query)]
        let response: SearchResponse = try await transport.request(
            method: .get, path: "/search", body: nil, query: params
        )
        return response.results
    }

    /// Returns `true` if the server is reachable and healthy.
    public func health() async throws -> Bool {
        let (_, response) = try await transport.rawRequest(
            method: .get, path: "/health", body: nil,
            contentType: nil, query: nil
        )
        return (200..<300).contains(response.statusCode)
    }
}
