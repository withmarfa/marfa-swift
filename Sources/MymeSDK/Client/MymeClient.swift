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

    /// Threads API: create, list, get, add/remove items.
    public let threads: ThreadsNamespace

    /// Blobs API: upload, download, check existence, get URLs.
    public let blobs: BlobsNamespace

    /// Types API: list, get, register, update, delete type schemas.
    public let types: TypesNamespace

    /// Keys API: create, list, revoke API keys.
    public let keys: KeysNamespace

    /// Webhooks API: create, list, get, update, delete, delivery history.
    public let webhooks: WebhooksNamespace

    // MARK: - Init

    /// Creates a client with the given configuration.
    public init(configuration: ClientConfiguration) {
        self.configuration = configuration
        let transport = URLSessionTransport(configuration: configuration)
        self.transport = transport

        self.items = ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: configuration.conflictStrategy
        )
        self.metadata = MetadataNamespace(transport: transport)
        self.extensions = ExtensionsNamespace(transport: transport)
        self.threads = ThreadsNamespace(transport: transport)
        self.blobs = BlobsNamespace(
            transport: transport,
            apiBaseURL: configuration.url,
            cdnBaseURL: configuration.cdnBaseURL
        )
        self.types = TypesNamespace(transport: transport)
        self.keys = KeysNamespace(transport: transport)
        self.webhooks = WebhooksNamespace(transport: transport)
    }

    /// Creates a client with a URL and API key using default settings.
    public convenience init(url: URL, apiKey: String) {
        self.init(configuration: ClientConfiguration(url: url, apiKey: apiKey))
    }

    /// Creates a client from environment variables (`MYME_API_URL`, `MYME_API_KEY`).
    /// Returns `nil` if the environment variables are not set.
    public static func fromEnvironment() -> MymeClient? {
        guard let config = ClientConfiguration.fromEnvironment else { return nil }
        return MymeClient(configuration: config)
    }

    /// Creates a client with a custom transport (for testing).
    init(configuration: ClientConfiguration, transport: any Transport) {
        self.configuration = configuration
        self.transport = transport

        self.items = ItemsNamespace(
            transport: transport,
            defaultConflictStrategy: configuration.conflictStrategy
        )
        self.metadata = MetadataNamespace(transport: transport)
        self.extensions = ExtensionsNamespace(transport: transport)
        self.threads = ThreadsNamespace(transport: transport)
        self.blobs = BlobsNamespace(
            transport: transport,
            apiBaseURL: configuration.url,
            cdnBaseURL: configuration.cdnBaseURL
        )
        self.types = TypesNamespace(transport: transport)
        self.keys = KeysNamespace(transport: transport)
        self.webhooks = WebhooksNamespace(transport: transport)
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
