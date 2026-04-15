import Foundation

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

    /// Threads API: thread records plus `in-thread` edge membership convenience.
    public let threads: ThreadsNamespace

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

    // MARK: - Init

    /// Designated init — used by every other init path, including tests.
    init(configuration: ClientConfiguration, transport: any Transport) {
        self.configuration = configuration
        self.transport = transport

        let items = ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: configuration.conflictStrategy
        )
        let edges = EdgesNamespace(transport: transport)
        self.items = items
        self.edges = edges
        self.metadata = MetadataNamespace(transport: transport)
        self.extensions = ExtensionsNamespace(transport: transport)
        self.threads = ThreadsNamespace(transport: transport, items: items, edges: edges)
        self.blobs = BlobsNamespace(
            transport: transport,
            apiBaseURL: configuration.url,
            cdnBaseURL: configuration.cdnBaseURL
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

    /// Creates a client from environment variables (`MYME_API_URL`, `MYME_API_KEY`).
    /// Returns `nil` if the environment variables are not set.
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
