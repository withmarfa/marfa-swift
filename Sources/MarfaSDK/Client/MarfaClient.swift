import Foundation
import SwiftData

/// Client for the Marfa API.
///
/// Provides namespaced access to all API endpoints:
///
///     let client = MarfaClient(url: serverURL, apiKey: key)
///     let item = try await client.items.create(
///         CreateItemInput(type: "core.note", properties: ["title": "Hello"])
///     )
///     let results = try await client.search(query: "hello")
///
/// For pure offline / on-device use, create a local-only client backed
/// by a SwiftData store — no API key or server URL required:
///
///     let client = try await MarfaClient.local(path: "/path/to/store.sqlite")
///     let note = try await client.items.create(
///         CreateItemInput(type: "core.note", properties: ["body": .string("Hello")])
///     )
///
/// The client is `Sendable` and safe to share across tasks and actors.
public final class MarfaClient: Sendable {

    /// The underlying transport (internal for testing).
    let transport: any Transport

    public let configuration: ClientConfiguration
    public let items: ItemsNamespace
    public let metadata: MetadataNamespace
    public let extensions: ExtensionsNamespace
    public let edges: EdgesNamespace
    public let blobs: BlobsNamespace
    public let types: TypesNamespace
    public let keys: KeysNamespace
    public let webhooks: WebhooksNamespace
    public let profile: ProfileNamespace
    public let connections: ConnectionsNamespace

    /// Credential id returned by ``createOAuthProvider(_:)`` or ``createApiToken(_:)``
    /// is passed as `credentialRef` on ``ConnectionsNamespace/install(_:)`` so
    /// multiple integrations of the same upstream share one credential row.
    public let credentials: CredentialsNamespace

    public let integrations: IntegrationsNamespace

    /// `client.tenants.{getConfig, setConfig}` are tenant-admin-gated;
    /// `client.tenants.quotas.{getOwn, getById, set}` mixes tenant and platform
    /// admin per method. The server enforces the role split.
    public let tenants: TenantsNamespace

    /// Platform-admin-only operator surface.
    /// Tenant quota read/write lives on ``tenants`` (`client.tenants.quotas.*`),
    /// not here.
    public let admin: AdminNamespace

    /// Post-sign-in account-lifecycle endpoints (`requestDelete`, `cancel`,
    /// `confirmDelete`). The OAuth / Passkey / DeviceFlow sign-in surfaces live
    /// under ``MarfaAuth``, ``Passkey``, and ``DeviceFlow``.
    public let auth: AuthNamespace

    /// The active sync engine, present only in synced mode (``MarfaClient/synced(url:apiKey:storePath:)``).
    ///
    /// Call ``SyncEngine/start()`` to begin synchronization and
    /// ``SyncEngine/stop()`` to tear it down gracefully.
    public let syncEngine: SyncEngine?

    /// The underlying ``ModelContainer``, non-nil when a local store is
    /// configured. Used by ``makeStore()`` to create ``MarfaStore``
    /// instances. `ModelContainer` is `Sendable` and safe to store on
    /// `MarfaClient`.
    private let container: ModelContainer?

    /// The mutation queue, non-nil when a local store is configured.
    /// Held so ``makeStore()`` can pass it to ``MarfaStore`` for the
    /// dropped-mutation dismissal forwarders. `MutationQueue` is an
    /// actor, so storing the reference is `Sendable`-safe.
    private let mutationQueue: MutationQueue?

    // MARK: - Init

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
        self.mutationQueue = mutationQueue

        let items = ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: configuration.conflictStrategy,
            localStore: localStore,
            mutationQueue: mutationQueue,
            apiBaseURL: configuration.url
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
        let isLocalMode = localStore != nil && syncEngine == nil
        self.blobs = BlobsNamespace(
            transport: transport,
            apiBaseURL: configuration.url,
            cdnBaseURL: configuration.cdnBaseURL,
            mutationQueue: syncEngine != nil ? mutationQueue : nil,
            isLocalMode: isLocalMode
        )
        self.types = TypesNamespace(transport: transport, isLocalMode: isLocalMode)
        self.keys = KeysNamespace(transport: transport, isLocalMode: isLocalMode)
        self.webhooks = WebhooksNamespace(transport: transport, isLocalMode: isLocalMode)
        self.profile = ProfileNamespace(transport: transport, isLocalMode: isLocalMode)
        self.connections = ConnectionsNamespace(
            transport: transport,
            items: items,
            isLocalMode: isLocalMode
        )
        self.credentials = CredentialsNamespace(transport: transport, isLocalMode: isLocalMode)
        self.integrations = IntegrationsNamespace(transport: transport, isLocalMode: isLocalMode)
        self.tenants = TenantsNamespace(transport: transport, isLocalMode: isLocalMode)
        self.admin = AdminNamespace(transport: transport, isLocalMode: isLocalMode)
        self.auth = AuthNamespace(transport: transport, isLocalMode: isLocalMode)
    }

    public convenience init(configuration: ClientConfiguration) {
        self.init(
            configuration: configuration,
            transport: URLSessionTransport(configuration: configuration)
        )
    }

    public convenience init(url: URL, apiKey: String) {
        self.init(configuration: ClientConfiguration(url: url, apiKey: apiKey))
    }

    /// Creates a client with an OAuth-issued ``TokenProvider``.
    ///
    /// Used by callers that obtain a ``TokenProvider`` from one of the
    /// auth flows — ``MarfaAuth``, ``DeviceFlow``, or ``Passkey``. The
    /// transport awaits ``TokenProvider/currentToken()`` on every
    /// request and refreshes once on `401`.
    public convenience init(url: URL, tokenProvider: any TokenProvider) {
        self.init(configuration: ClientConfiguration(url: url, tokenProvider: tokenProvider))
    }

    /// Creates a pure-local client backed by a SwiftData store at `path`.
    ///
    /// No server URL or API key is required. All namespace calls
    /// resolve against the local store. Pass `":memory:"` for an
    /// ephemeral store (useful in tests).
    ///
    /// This is a convenience over ``MarfaClient/local(container:)`` for
    /// callers who want the SDK to build the container for them.
    /// Consumers that need to configure the container directly — for
    /// example to enable CloudKit mirroring via
    /// `MarfaModelContainer.make(path:cloudKitDatabase:)` — should build
    /// the container themselves and call ``MarfaClient/local(container:)``.
    ///
    /// `async` because the underlying `LocalStore` is constructed off
    /// the main actor via `Task.detached` — `@ModelActor`'s synthesized
    /// init binds the actor's executor to whatever actor calls it, so
    /// calling from `@MainActor` would silently route every method onto
    /// the main thread.
    ///
    /// - Throws: ``LocalStoreError`` if the database cannot be opened or
    ///   migrated.
    public static func local(path: String) async throws -> MarfaClient {
        let container = try MarfaModelContainer.make(path: path)
        return try await local(container: container)
    }

    /// Creates a pure-local client backed by a caller-supplied
    /// ``ModelContainer``.
    ///
    /// Use this when you need to control how the container is built —
    /// for example, to enable CloudKit mirroring by passing
    /// `cloudKitDatabase: .automatic(containerIdentifier: "iCloud.…")` to
    /// ``MarfaModelContainer/make(path:cloudKitDatabase:)``:
    ///
    ///     let container = try MarfaModelContainer.make(
    ///         path: path,
    ///         cloudKitDatabase: .automatic(containerIdentifier: "iCloud.example.app")
    ///     )
    ///     let client = try await MarfaClient.local(container: container)
    ///
    /// All namespace calls resolve against the local store; no server URL
    /// or API key is required. The transport is never invoked in
    /// pure-local mode.
    ///
    /// `async` because the underlying `LocalStore` is constructed off
    /// the main actor via `Task.detached` — `@ModelActor`'s synthesized
    /// init binds the actor's executor to whatever actor calls it, so
    /// calling from `@MainActor` would silently route every method onto
    /// the main thread.
    public static func local(container: ModelContainer) async throws -> MarfaClient {
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        // Transport is never invoked in pure-local mode — every namespace
        // method checks `localStore` first. URL is a placeholder; the
        // fallback guards against `local://offline` failing to parse in a
        // future SDK.
        let config = ClientConfiguration(
            url: URL(string: "local://offline") ?? URL(fileURLWithPath: "/dev/null"),
            apiKey: ""
        )
        return MarfaClient(
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
    /// returned ``SyncEngine`` (via ``MarfaClient/syncEngine``) must be
    /// started by the caller:
    ///
    ///     let client = try await MarfaClient.synced(url: serverURL, apiKey: key, storePath: dbPath)
    ///     await client.syncEngine?.start()
    ///
    /// - Parameters:
    ///   - url: Base URL of the Marfa API.
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
    ) async throws -> MarfaClient {
        let config = ClientConfiguration(url: url, apiKey: apiKey)
        return try await synced(
            configuration: config,
            storePath: storePath,
            connectionManager: connectionManager
        )
    }

    /// Synced-mode factory for OAuth-tokened callers.
    ///
    /// Mirrors ``synced(url:apiKey:storePath:connectionManager:)`` but
    /// accepts a ``TokenProvider`` directly — required for the
    /// "Sign in with Marfa + sync" flow used by Notes / Messages.
    /// The transport awaits ``TokenProvider/currentToken()`` on every
    /// request and refreshes once on `401`; sync replay rides the same
    /// auth path.
    ///
    /// - Parameters:
    ///   - url: Base URL of the Marfa API.
    ///   - tokenProvider: OAuth token provider returned by ``MarfaAuth``,
    ///     ``DeviceFlow``, or ``Passkey``.
    ///   - storePath: Path to the SwiftData store file. Pass `":memory:"`
    ///     for tests.
    ///   - connectionManager: Optional pre-built manager; the default
    ///     creates one.
    public static func synced(
        url: URL,
        tokenProvider: any TokenProvider,
        storePath: String,
        connectionManager: ConnectionStateManager = ConnectionStateManager()
    ) async throws -> MarfaClient {
        let config = ClientConfiguration(url: url, tokenProvider: tokenProvider)
        return try await synced(
            configuration: config,
            storePath: storePath,
            connectionManager: connectionManager
        )
    }

    private static func synced(
        configuration config: ClientConfiguration,
        storePath: String,
        connectionManager: ConnectionStateManager
    ) async throws -> MarfaClient {
        let transport = URLSessionTransport(configuration: config)
        let container = try MarfaModelContainer.make(path: storePath)
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let queue = await Task.detached { MutationQueue(modelContainer: container) }.value
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connectionManager
        )
        return MarfaClient(
            configuration: config,
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            syncEngine: engine,
            container: container
        )
    }

    /// Creates a client from environment variables (`MARFA_API_URL`,
    /// `MARFA_API_KEY`). Returns `nil` if the environment variables are
    /// not set.
    public static func fromEnvironment() -> MarfaClient? {
        guard let config = ClientConfiguration.fromEnvironment() else { return nil }
        return MarfaClient(configuration: config)
    }

    /// Creates a client by loading the API key from the system Keychain.
    ///
    /// - Parameters:
    ///   - service: Keychain service. Defaults to `"marfa.sdk"`.
    ///   - account: Keychain account identifier (typically the server
    ///     hostname or a named environment).
    ///   - url: Base URL of the Marfa API.
    ///   - accessGroup: Optional access group for app-extension sharing.
    /// - Throws: ``KeychainError`` if the item is missing or unreadable.
    public static func fromKeychain(
        service: String = "marfa.sdk",
        account: String,
        url: URL,
        accessGroup: String? = nil
    ) async throws -> MarfaClient {
        let storage = KeychainStorage(service: service, accessGroup: accessGroup)
        return try await fromSecureStorage(service: service, account: account, url: url, storage: storage)
    }

    /// Protocol-based variant — accepts any ``SecureStorage`` so tests can inject an
    /// in-memory keychain without touching the system keychain.
    public static func fromSecureStorage(
        service: String = "marfa.sdk",
        account: String,
        url: URL,
        storage: any SecureStorage
    ) async throws -> MarfaClient {
        guard let apiKey = try await storage.get(for: account) else {
            throw KeychainError.osStatus(errSecItemNotFound)
        }
        return MarfaClient(url: url, apiKey: apiKey)
    }

    public func saveToKeychain(
        service: String = "marfa.sdk",
        account: String,
        accessGroup: String? = nil
    ) async throws {
        let storage = KeychainStorage(service: service, accessGroup: accessGroup)
        try await storage.set(configuration.apiKey, for: account)
    }

    // MARK: - Reactive store

    /// Creates a ``MarfaStore`` for use with SwiftUI and `@Observable`.
    ///
    /// Returns `nil` when the client has no local store configured (i.e.
    /// it was created with ``MarfaClient/init(url:apiKey:)`` or
    /// ``MarfaClient/init(configuration:)`` without a local store path).
    ///
    /// Must be called from a `@MainActor` context. Callers typically
    /// hold the returned store as a `@State` or environment object in a
    /// SwiftUI view:
    ///
    ///     @State private var store = client.makeStore()
    ///     // ...
    ///     let notes = store?.query(filters: ListFilters(type: "core.note"))
    ///
    /// Each call to `makeStore()` returns a new `MarfaStore` instance
    /// backed by the same underlying ``ModelContainer`` — multiple
    /// stores observe the same data.
    @MainActor
    public func makeStore() -> MarfaStore? {
        guard let container else { return nil }
        return MarfaStore(
            container: container,
            syncEngine: syncEngine,
            mutationQueue: mutationQueue,
            profileNamespace: profile
        )
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
