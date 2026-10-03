import Foundation
import MarfaCore
import MarfaCoreNames

/// Every way the core refuses or fails. `code` is the server's, where the
/// server answered.
public enum MarfaError: Error, Sendable, Hashable, LocalizedError {
    case notFound(code: String, message: String)
    case unauthorized(code: String, message: String)
    case forbidden(code: String, message: String)
    case validation(code: String, message: String)
    case unknownType(message: String)
    case rateLimited(code: String, message: String, retryAfterSeconds: UInt64?)
    case server(status: UInt16, code: String, message: String)
    case io(message: String)
    case network(message: String)
    /// A response from something in front of the server, without its contract.
    case unnamed(status: UInt16, message: String)
    case decoding(message: String)
    case store(message: String)
    case storageFull(message: String)
    case signedOut(origin: String, message: String)
    case noKeychain(message: String)
    case redirected(origin: String, status: UInt16, location: String?, message: String)
    case noServer(message: String)
    case noCursor(message: String)
    case hydrationIncomplete(message: String)
    /// The copy has never held the server's type catalog; a hydration reads
    /// it.
    case noCatalog(message: String)
    /// The store at `path` has a shape this build cannot read. `unsent`
    /// names the writes another build can still send, where the queue is readable.
    case wrongSchema(path: String, reason: String, unsent: UInt64?, message: String)
    case readingHandle(message: String)
    /// Hydration is needed to make the copy current; its queue is kept.
    case copyExpired(reason: String, message: String)
    case streamIncomplete(reason: String, message: String)
    case wrongServer(expected: String, got: String, message: String)
    /// The item is whole and its bytes are not here, nor can they be fetched.
    case bytesAbsent(hash: String, reason: String, message: String)
    /// The server speaks a contract this build was not made for, and its
    /// answer was not read. `served` is the contract the answer named, or nil
    /// where a success named none. Where `writeSent`, the answer was to a
    /// write, which may have taken effect: it stays queued, and goes again
    /// under its idempotency key once the app speaks the server's contract.
    /// `status` is nil when the failure carries no HTTP status.
    case contractMismatch(served: String?, expected: UInt64, status: UInt16?, writeSent: Bool, message: String)
    case invalid(message: String)
    /// The working copy was closed, or failed to reopen its store with a new
    /// key; it is gone for good, and the app opens the store again.
    case closed(message: String)

    /// Fit to show a person.
    public var message: String {
        switch self {
        case .notFound(_, let message), .unauthorized(_, let message), .forbidden(_, let message),
            .validation(_, let message), .unknownType(let message), .rateLimited(_, let message, _),
            .server(_, _, let message), .io(let message), .network(let message), .unnamed(_, let message),
            .decoding(let message),
            .store(let message), .storageFull(let message), .signedOut(_, let message),
            .noKeychain(let message), .redirected(_, _, _, let message),
            .noServer(let message), .noCursor(let message), .hydrationIncomplete(let message), .noCatalog(let message),
            .wrongSchema(_, _, _, let message), .readingHandle(let message), .copyExpired(_, let message),
            .streamIncomplete(_, let message), .wrongServer(_, _, let message), .bytesAbsent(_, _, let message),
            .contractMismatch(_, _, _, _, let message), .invalid(let message), .closed(let message):
            message
        }
    }

    public var errorDescription: String? { message }

    init(_ error: CoreMarfaError) {
        switch error {
        case .NotFound(let code, let message): self = .notFound(code: code, message: message)
        case .Unauthorized(let code, let message): self = .unauthorized(code: code, message: message)
        case .Forbidden(let code, let message): self = .forbidden(code: code, message: message)
        case .Validation(let code, let message): self = .validation(code: code, message: message)
        case .UnknownType(let message): self = .unknownType(message: message)
        case .RateLimited(let code, let message, let retryAfterSeconds):
            self = .rateLimited(code: code, message: message, retryAfterSeconds: retryAfterSeconds)
        case .Server(let status, let code, let message): self = .server(status: status, code: code, message: message)
        case .Io(let message): self = .io(message: message)
        case .Network(let message): self = .network(message: message)
        case .Unnamed(let status, let message): self = .unnamed(status: status, message: message)
        case .Decoding(let message): self = .decoding(message: message)
        case .Store(let message): self = .store(message: message)
        case .StorageFull(let message): self = .storageFull(message: message)
        case .SignedOut(let origin, let message): self = .signedOut(origin: origin, message: message)
        case .NoKeychain(let message): self = .noKeychain(message: message)
        case .Redirected(let origin, let status, let location, let message):
            self = .redirected(origin: origin, status: status, location: location, message: message)
        case .NoServer(let message): self = .noServer(message: message)
        case .NoCursor(let message): self = .noCursor(message: message)
        case .HydrationIncomplete(let message): self = .hydrationIncomplete(message: message)
        case .NoCatalog(let message): self = .noCatalog(message: message)
        case .WrongSchema(let path, let reason, let unsent, let message):
            self = .wrongSchema(path: path, reason: reason, unsent: unsent, message: message)
        case .ReadingHandle(let message): self = .readingHandle(message: message)
        case .CopyExpired(let reason, let message):
            self = .copyExpired(reason: reason, message: message)
        case .StreamIncomplete(let reason, let message): self = .streamIncomplete(reason: reason, message: message)
        case .WrongServer(let expected, let got, let message):
            self = .wrongServer(expected: expected, got: got, message: message)
        case .BytesAbsent(let hash, let reason, let message):
            self = .bytesAbsent(hash: hash, reason: reason, message: message)
        case .ContractMismatch(let served, let expected, let status, let writeSent, let message):
            self = .contractMismatch(
                served: served, expected: expected, status: status, writeSent: writeSent, message: message)
        case .Invalid(let message): self = .invalid(message: message)
        }
    }
}

public struct Item: Sendable, Hashable, Identifiable {
    public let id: String
    public let type: String
    public let properties: [String: JSONValue]
    public let state: ItemState
    public let tier: Tier?
    public let version: Int64
    public let schemaVersion: Int64
    public let source: String
    public let sourceId: String?
    public let occurredAt: String
    public let createdAt: String
    public let updatedAt: String
    public let tags: [String]

    /// For an app's previews and tests.
    public init(
        id: String, type: String, properties: [String: JSONValue], state: ItemState, tier: Tier?, version: Int64,
        schemaVersion: Int64, source: String, sourceId: String?, occurredAt: String, createdAt: String,
        updatedAt: String, tags: [String]
    ) {
        self.id = id
        self.type = type
        self.properties = properties
        self.state = state
        self.tier = tier
        self.version = version
        self.schemaVersion = schemaVersion
        self.source = source
        self.sourceId = sourceId
        self.occurredAt = occurredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
    }

    init(_ item: CoreItem) throws {
        id = item.id
        type = item.type
        properties = try Properties.object(item.propertiesJson)
        state = ItemState(item.state)
        tier = item.tier.map(Tier.init)
        version = item.version
        schemaVersion = item.schemaVersion
        source = item.source
        sourceId = item.sourceId
        occurredAt = item.occurredAt
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        tags = item.tags
    }

    public var title: String? { properties["title"]?.string }
}

public struct Edge: Sendable, Hashable, Identifiable {
    public let id: String
    public let sourceId: String
    public let targetId: String
    public let edgeType: String
    public let properties: [String: JSONValue]
    public let version: Int64
    public let createdAt: String
    public let updatedAt: String

    /// For an app's previews and tests.
    public init(
        id: String, sourceId: String, targetId: String, edgeType: String, properties: [String: JSONValue],
        version: Int64, createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.edgeType = edgeType
        self.properties = properties
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(_ edge: CoreEdge) throws {
        id = edge.id
        sourceId = edge.sourceId
        targetId = edge.targetId
        edgeType = edge.edgeType
        properties = try Properties.object(edge.propertiesJson)
        version = edge.version
        createdAt = edge.createdAt
        updatedAt = edge.updatedAt
    }
}

public struct SearchHit: Sendable, Hashable {
    public let item: Item
    public let score: Double
    public let snippet: String

    init(_ hit: CoreSearchHit) throws {
        item = try Item(hit.item)
        score = hit.score
        snippet = hit.snippet
    }
}

/// A create, before it is queued.
///
/// The tags are queued as writes of their own. Where `sourceId` names a row
/// the server already holds, the create lands on it, and `baseVersion` makes
/// that conditional on the version it was read at. With no `tier`, the key's
/// default tier decides, which may be outside the copy's slice: the copy
/// then drops the item once the server's event for it arrives.
public struct Draft: Sendable, Hashable {
    public var type: String
    public var properties: [String: JSONValue]
    public var tags: [String]
    public var tier: Tier?
    public var id: String?
    public var source: String?
    public var sourceId: String?
    public var occurredAt: String?
    public var baseVersion: Int64?

    public init(
        type: String, properties: [String: JSONValue] = [:], tags: [String] = [], tier: Tier? = nil,
        id: String? = nil, source: String? = nil, sourceId: String? = nil, occurredAt: String? = nil,
        baseVersion: Int64? = nil
    ) {
        self.type = type
        self.properties = properties
        self.tags = tags
        self.tier = tier
        self.id = id
        self.source = source
        self.sourceId = sourceId
        self.occurredAt = occurredAt
        self.baseVersion = baseVersion
    }

    func core() throws -> CoreDraft {
        CoreDraft(
            type: type, id: id, propertiesJson: try Properties.text(properties), tags: tags, tier: tier?.core,
            source: source, sourceId: sourceId, occurredAt: occurredAt, baseVersion: baseVersion)
    }
}

/// Each property given replaces its whole value.
public struct Edit: Sendable, Hashable {
    public var properties: [String: JSONValue]
    public var baseVersion: Int64
    public var sourceId: String?

    public init(properties: [String: JSONValue], baseVersion: Int64, sourceId: String? = nil) {
        self.properties = properties
        self.baseVersion = baseVersion
        self.sourceId = sourceId
    }

    func core() throws -> CoreEdit {
        CoreEdit(propertiesJson: try Properties.text(properties), baseVersion: baseVersion, sourceId: sourceId)
    }
}

/// With `state` unset, a list answers active items only; `allStates` lifts
/// that, and a named `state` wins over both.
public struct ListFilters: Sendable, Hashable {
    public var type: String?
    public var state: ItemState?
    public var allStates: Bool
    public var tier: Tier?
    public var tags: [String]
    public var occurredAfter: String?
    public var occurredBefore: String?
    /// The server's listing grammar; back-reference conditions are not local.
    public var filter: String?
    /// This item and its held descendants through `parent-of` edges.
    public var beneath: String?
    public var limit: UInt32?
    public var offset: UInt32?

    public init(
        type: String? = nil, state: ItemState? = nil, allStates: Bool = false, tier: Tier? = nil,
        tags: [String] = [], occurredAfter: String? = nil, occurredBefore: String? = nil,
        filter: String? = nil, beneath: String? = nil, limit: UInt32? = nil, offset: UInt32? = nil
    ) {
        self.type = type
        self.state = state
        self.allStates = allStates
        self.tier = tier
        self.tags = tags
        self.occurredAfter = occurredAfter
        self.occurredBefore = occurredBefore
        self.filter = filter
        self.beneath = beneath
        self.limit = limit
        self.offset = offset
    }

    var core: CoreListFilters {
        CoreListFilters(
            type: type, state: state?.core, allStates: allStates, tier: tier?.core, tags: tags,
            occurredAfter: occurredAfter, occurredBefore: occurredBefore, filter: filter, beneath: beneath,
            limit: limit, offset: offset)
    }
}

/// `state` and `allStates` work as in `ListFilters`. `type` includes its
/// subtree, and every tag given must be present.
public struct SearchFilters: Sendable, Hashable {
    public var type: String?
    public var state: ItemState?
    public var allStates: Bool
    public var tags: [String]
    public var filter: String?
    public var beneath: String?

    public init(
        type: String? = nil, state: ItemState? = nil, allStates: Bool = false, tags: [String] = [],
        filter: String? = nil, beneath: String? = nil
    ) {
        self.type = type
        self.state = state
        self.allStates = allStates
        self.tags = tags
        self.filter = filter
        self.beneath = beneath
    }

    var core: CoreSearchFilters {
        CoreSearchFilters(
            state: state?.core, allStates: allStates, type: type, tags: tags, filter: filter, beneath: beneath)
    }
}
