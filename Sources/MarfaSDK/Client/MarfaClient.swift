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

    /// `client.spaces.{getConfig, setConfig}` are space-admin-gated;
    /// `client.spaces.quotas.{getOwn, getById, set}` mixes space and platform
    /// admin per method. The server enforces the role split.
    public let spaces: SpacesNamespace

    /// Platform-admin-only operator surface.
    /// Space quota read/write lives on ``spaces`` (`client.spaces.quotas.*`),
    /// not here.
    public let admin: AdminNamespace

    /// Post-sign-in account-lifecycle endpoints (`requestDelete`, `cancel`,
    /// `confirmDelete`). The OAuth / Passkey / DeviceFlow sign-in surfaces live
    /// under ``MarfaAuth``, ``Passkey``, and ``DeviceFlow``.
    public let auth: AuthNamespace

    /// Non-`nil` when this client's store could not be opened and had to be
    /// rebuilt empty — see ``StoreRecovery``. `nil` on every ordinary open,
    /// and on a client built from a caller-supplied container, which the SDK
    /// did not open.
    ///
    /// A synced client also announces it once on ``SyncEngine/events`` as
    /// ``SyncEvent/storeRecovered(_:)``. This property is the answer for a
    /// pure-local client, which has no engine, and for any app that would
    /// rather ask than subscribe.
    public let storeRecovery: StoreRecovery?

    /// The writer lock this client holds over its store, if any.
    ///
    /// Held for the client's lifetime rather than per write: the thing being
    /// excluded is a second *engine*, not a second statement.
    let storeWriterLock: StoreWriterLock?

    /// Whether this client may write to its store.
    ///
    /// `false` when another process — or another client in this one — already
    /// holds it. A read-only client answers reads from the store and does not
    /// drain, so its queue is somebody else's to send. ``storeHeldBy`` says
    /// whose.
    public var holdsStoreWriteLock: Bool { storeWriterLock?.writer ?? true }

    /// Who holds the store's writer lock, when this client does not.
    public var storeHeldBy: StoreLockHolder? { storeWriterLock?.heldBy }

    /// Gives the store's writer lock back when the client goes away.
    ///
    /// **Without this the lock was taken and never released.** A client that
    /// is discarded held its store's path for the life of the process, so a
    /// replacement built over the same path — an app rebuilding its client
    /// after a sign-out, a test making two in a row — was refused with nothing
    /// to release. Cross-process that heals on its own through the staleness
    /// check, because the holder is gone; in-process it does not, because the
    /// holder is still running.
    ///
    /// Releasing compares this hold's own token, so a client that lost its
    /// lock to a takeover cannot delete whoever holds it now.
    deinit {
        storeWriterLock?.release()
    }

    /// The active sync engine, present only in synced mode (``MarfaClient/synced(url:apiKey:storePath:)``).
    ///
    /// Call ``SyncEngine/start()`` to begin synchronization and
    /// ``SyncEngine/stop()`` to tear it down gracefully.
    public let syncEngine: SyncEngine?

    /// Where a synced client's `.callback` conflict strategy finds its
    /// resolver. Non-nil there and `nil` on both other clients: a direct
    /// (server-only) client reaches the per-call closure itself and queues
    /// nothing, and a local-only client never syncs, so no conflict arises for
    /// a resolver to handle.
    private let conflictResolvers: ConflictResolverRegistry?

    /// Installs the resolver that replayed `.callback` updates run through.
    ///
    /// A resolver closure cannot be written to the mutation queue, so in
    /// synced mode it is registered on the client instead of passed per call.
    /// Register before the first write and before starting the sync engine:
    /// a `.callback` update with no resolver registered is refused at the call
    /// site rather than quietly resolving under a different strategy.
    ///
    /// No-op on either client without a mutation queue, and for different
    /// reasons. A direct client has no queue because it talks to the server
    /// synchronously, so it calls the per-call closure itself and never needs
    /// a registered one. A local-only client has no queue because it never
    /// syncs, so no conflict can arise and no resolver would ever run; a
    /// `.callback` update there is refused at the call site and says so.
    public func registerConflictResolver(_ resolver: @escaping ConflictResolver) async {
        await conflictResolvers?.register(resolver)
    }

    /// The underlying ``ModelContainer``, non-nil when a local store is
    /// configured. Used by ``makeStore()`` to create ``MarfaStore``
    /// instances. `ModelContainer` is `Sendable` and safe to store on
    /// `MarfaClient`.
    private let container: ModelContainer?

    /// The mutation queue, non-nil when a local store is configured.
    /// Held so ``makeStore()`` can pass it to ``MarfaStore`` for the
    /// dropped-mutation dismissal forwarders. `MutationQueue` is an
    /// actor, so storing the reference is `Sendable`-safe.
    ///
    /// Internal rather than private so a test can stage a queue state the
    /// namespaces cannot produce — a mutation enqueued twice, say. Still not
    /// public: a consumer writing to the queue behind the namespaces is how a
    /// client and its queued work get out of step.
    let mutationQueue: MutationQueue?

    /// The local store, non-nil whenever a container is configured.
    /// Namespaces receive it directly; the client keeps its own
    /// reference so ``makeStore()`` can hand it to ``MarfaStore`` and so
    /// ``search(query:filters:)`` can resolve locally in pure-local mode.
    /// `LocalStore` is an actor, so storing the reference is
    /// `Sendable`-safe.
    ///
    /// Internal rather than private so the account-ownership extension can
    /// reach it from its own file. Still not public: a consumer reaching into
    /// the store directly is how a client and its store get out of step.
    let localStore: LocalStore?

    // MARK: - Init

    init(
        configuration: ClientConfiguration,
        transport: any Transport,
        localStore: LocalStore? = nil,
        mutationQueue: MutationQueue? = nil,
        syncEngine: SyncEngine? = nil,
        container: ModelContainer? = nil,
        conflictResolvers: ConflictResolverRegistry? = nil,
        storeRecovery: StoreRecovery? = nil,
        storeWriterLock: StoreWriterLock? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.storeRecovery = storeRecovery
        self.storeWriterLock = storeWriterLock
        self.syncEngine = syncEngine
        self.container = container
        self.mutationQueue = mutationQueue
        self.localStore = localStore
        self.conflictResolvers = conflictResolvers

        let items = ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: configuration.conflictStrategy,
            localStore: localStore,
            mutationQueue: mutationQueue,
            apiBaseURL: configuration.url,
            conflictResolvers: conflictResolvers
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
            localStore: localStore,
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
        self.spaces = SpacesNamespace(transport: transport, isLocalMode: isLocalMode)
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
        let opened = try MarfaModelContainer.open(path: path)
        return try await local(container: opened.container, storeRecovery: opened.recovery)
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
        try await local(container: container, storeRecovery: nil)
    }

    private static func local(
        container: ModelContainer,
        storeRecovery: StoreRecovery?
    ) async throws -> MarfaClient {
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
            container: container,
            storeRecovery: storeRecovery
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
    /// That is the whole of it. Starting the engine catches the store up
    /// before it subscribes to live events: anything queued replays, and a
    /// store that has never synced imports what the server already holds.
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
        connectionManager: ConnectionStateManager = ConnectionStateManager(),
        maxReplayAttempts: Int = 5
    ) async throws -> MarfaClient {
        let config = ClientConfiguration(url: url, apiKey: apiKey)
        return try await synced(
            configuration: config,
            storePath: storePath,
            connectionManager: connectionManager,
            maxReplayAttempts: maxReplayAttempts
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
    ///   - maxReplayAttempts: How many times a queued write is retried after a
    ///     refusal that is neither permanent nor self-evidently unresolvable
    ///     before it is blocked. Network-class failures are exempt and retry
    ///     without bound. Must be at least 1.
    public static func synced(
        url: URL,
        tokenProvider: any TokenProvider,
        storePath: String,
        connectionManager: ConnectionStateManager = ConnectionStateManager(),
        maxReplayAttempts: Int = 5
    ) async throws -> MarfaClient {
        let config = ClientConfiguration(url: url, tokenProvider: tokenProvider)
        return try await synced(
            configuration: config,
            storePath: storePath,
            connectionManager: connectionManager,
            maxReplayAttempts: maxReplayAttempts
        )
    }

    private static func synced(
        configuration config: ClientConfiguration,
        storePath: String,
        connectionManager: ConnectionStateManager,
        maxReplayAttempts: Int
    ) async throws -> MarfaClient {
        let transport = URLSessionTransport(configuration: config)

        // **Taken before the store is opened**, because a store this build
        // cannot read must not be moved aside by a caller that does not hold
        // the write — the quarantine inside `open` is exactly that move.
        //
        // A second opener is told it cannot write rather than being queued:
        // a caller can do something useful with a read-only store and nothing
        // at all with a promise that has not settled. Two engines over one
        // store is the failure this prevents, and it had nothing stopping it
        // — an app and a share extension over an App Group container got two
        // drains and two cursors with nothing anywhere saying so.
        let writerLock = try StoreWriterLock.acquire(storePath: storePath)

        // **The lock is consulted here, and taking it before the open was
        // pointless until it was.** The stated reason for that ordering is
        // that a store this build cannot read must not be moved aside by a
        // caller without the write — and moving it aside is exactly what
        // `open`'s fail-safe does. A reader reaching that path quarantines the
        // writer's store out from under it.
        //
        // So a reader opens without the fail-safe. If the store will not open
        // for it, that is the writer's problem to discover and repair, and a
        // second client must not decide it on the writer's behalf.
        let opened = writerLock.writer
            ? try MarfaModelContainer.open(path: storePath)
            : StoreOpenResult(
                container: try MarfaModelContainer.make(path: storePath), recovery: nil
            )
        let container = opened.container
        let store = await Task.detached { LocalStore(modelContainer: container) }.value
        let queue = await Task.detached { MutationQueue(modelContainer: container) }.value
        // One registry, shared by the write path and the replay path. The
        // write path checks a `.callback` update can reach a resolver before
        // queueing it; the replay path is what actually calls it.
        let resolvers = ConflictResolverRegistry()
        let engine = SyncEngine(
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            connectionManager: connectionManager,
            conflictResolvers: resolvers,
            maxReplayAttempts: maxReplayAttempts,
            storeRecovery: opened.recovery,
            isStoreWriter: writerLock.writer
        )
        return MarfaClient(
            configuration: config,
            transport: transport,
            localStore: store,
            mutationQueue: queue,
            syncEngine: engine,
            container: container,
            conflictResolvers: resolvers,
            storeRecovery: opened.recovery,
            storeWriterLock: writerLock
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
        // Container and local store are configured together by every
        // factory, so this either yields both or neither.
        guard let container, let localStore else { return nil }
        return MarfaStore(
            container: container,
            localStore: localStore,
            syncEngine: syncEngine,
            mutationQueue: mutationQueue,
            profileNamespace: profile
        )
    }

    // MARK: - Top-Level Methods

    /// Full-text search across items.
    ///
    /// **Served locally whenever this client has a store**, synced or
    /// not. One interface, local baseline: a search on a synced client
    /// used to become a network round trip while a working local path
    /// sat switched off beside it, which made the same call mean two
    /// different things depending on a setting the caller had set once
    /// and forgotten.
    ///
    /// Local results are ranked and filtered differently from the
    /// server's FTS index, and the divergences are listed in full on
    /// ``LocalStore/searchItems(text:filters:)``. The short version: the
    /// local path matches substrings rather than terms, has no BM25
    /// ranking and no snippets, and can only see what has synced. Ask
    /// the server explicitly with ``searchRemote(query:filters:)`` when
    /// a query needs the index rather than the baseline — a ranked feed,
    /// say, or a corpus larger than the device holds.
    public func search(query: String, filters: SearchFilters? = nil) async throws -> [SearchResult] {
        if let localStore {
            return try await localStore.searchItems(text: query, filters: filters)
        }
        return try await searchRemote(query: query, filters: filters)
    }

    /// Search through the server's index, bypassing the local store.
    ///
    /// The escape hatch for the cases the local baseline cannot answer:
    /// BM25 ranking, `<mark>` snippets, and a corpus wider than what has
    /// synced to this device. Requires a server — a pure-local client
    /// has none to ask.
    public func searchRemote(query: String, filters: SearchFilters? = nil) async throws -> [SearchResult] {
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
