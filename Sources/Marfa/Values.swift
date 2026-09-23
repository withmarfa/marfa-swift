import Foundation
import MarfaCore

// The core's own values, under the package's names. Each already says what
// the package would: a closed set, or a record with nothing to translate.
public typealias Tier = CoreTier
public typealias ItemState = CoreItemState
public typealias WriteKind = CoreWriteKind
public typealias Verdict = CoreVerdict
public typealias BlockedReason = CoreBlockedReason
public typealias Handle = CoreHandle
public typealias Hydration = CoreHydration
public typealias SortField = CoreSortField
public typealias SortDirection = CoreSortDirection
public typealias Sort = CoreSort
public typealias QueuedWrite = CoreQueuedWrite
public typealias DrainReport = CoreDrainReport
public typealias DrainVerdict = CoreDrainVerdict
public typealias HydrateReport = CoreHydrateReport
public typealias CatchUpReport = CoreCatchUpReport
public typealias Status = CoreStatus
public typealias Attachment = CoreAttachment
public typealias Attached = CoreAttached
/// Every way the core refuses or fails, each case carrying the core's own
/// sentence and, where the server answered, its code.
public typealias MarfaError = CoreMarfaError

/// An item as the working copy holds it.
public struct Item: Sendable, Hashable, Identifiable {
    public let id: String
    public let type: String
    public let properties: [String: JSONValue]
    public let state: ItemState
    public let tier: Tier?
    public let version: Int64
    public let source: String
    public let sourceId: String?
    public let occurredAt: String
    public let createdAt: String
    public let updatedAt: String
    public let tags: [String]

    init(_ item: CoreItem) throws {
        id = item.id
        type = item.type
        properties = try Properties.object(item.propertiesJson)
        state = item.state
        tier = item.tier
        version = item.version
        source = item.source
        sourceId = item.sourceId
        occurredAt = item.occurredAt
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        tags = item.tags
    }

    /// The `title` property, where it is text.
    public var title: String? { properties["title"]?.string }
}

/// An edge as the working copy holds it.
public struct Edge: Sendable, Hashable, Identifiable {
    public let id: String
    public let sourceId: String
    public let targetId: String
    public let edgeType: String
    public let properties: [String: JSONValue]
    public let version: Int64

    init(_ edge: CoreEdge) throws {
        id = edge.id
        sourceId = edge.sourceId
        targetId = edge.targetId
        edgeType = edge.edgeType
        properties = try Properties.object(edge.propertiesJson)
        version = edge.version
    }
}

/// A search result: the item, how well it matched, and the text around the
/// match.
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

/// A create, before it is queued. The tags are queued as writes of their own.
public struct Draft: Sendable, Hashable {
    public var type: String
    public var properties: [String: JSONValue]
    public var tags: [String]
    public var tier: Tier?
    public var id: String?
    public var sourceId: String?
    public var occurredAt: String?

    public init(
        type: String, properties: [String: JSONValue] = [:], tags: [String] = [], tier: Tier? = nil,
        id: String? = nil, sourceId: String? = nil, occurredAt: String? = nil
    ) {
        self.type = type
        self.properties = properties
        self.tags = tags
        self.tier = tier
        self.id = id
        self.sourceId = sourceId
        self.occurredAt = occurredAt
    }

    func core() throws -> CoreDraft {
        CoreDraft(
            type: type, id: id, propertiesJson: try Properties.text(properties), tags: tags, tier: tier,
            source: nil, sourceId: sourceId, occurredAt: occurredAt, baseVersion: nil)
    }
}

/// A change to an item: whole field values, and the version it was read at.
public struct Edit: Sendable, Hashable {
    public var properties: [String: JSONValue]
    public var baseVersion: Int64

    public init(properties: [String: JSONValue], baseVersion: Int64) {
        self.properties = properties
        self.baseVersion = baseVersion
    }

    func core() throws -> CoreEdit {
        CoreEdit(propertiesJson: try Properties.text(properties), baseVersion: baseVersion, sourceId: nil)
    }
}

/// Narrowing for a list. Leaving `state` unset answers the active state, as
/// the server does; `allStates` lifts that, and a named state wins.
public struct ListFilters: Sendable, Hashable {
    public var type: String?
    public var state: ItemState?
    public var allStates: Bool
    public var tier: Tier?
    public var tags: [String]
    public var occurredAfter: String?
    public var occurredBefore: String?
    public var limit: UInt32?
    public var offset: UInt32?

    public init(
        type: String? = nil, state: ItemState? = nil, allStates: Bool = false, tier: Tier? = nil,
        tags: [String] = [], occurredAfter: String? = nil, occurredBefore: String? = nil,
        limit: UInt32? = nil, offset: UInt32? = nil
    ) {
        self.type = type
        self.state = state
        self.allStates = allStates
        self.tier = tier
        self.tags = tags
        self.occurredAfter = occurredAfter
        self.occurredBefore = occurredBefore
        self.limit = limit
        self.offset = offset
    }

    var core: CoreListFilters {
        CoreListFilters(
            type: type, state: state, allStates: allStates, tier: tier, tags: tags,
            occurredAfter: occurredAfter, occurredBefore: occurredBefore, limit: limit, offset: offset)
    }
}

/// Narrowing for a search: a list's state rule, a type with its subtree,
/// and every tag given.
public struct SearchFilters: Sendable, Hashable {
    public var type: String?
    public var state: ItemState?
    public var allStates: Bool
    public var tags: [String]

    public init(type: String? = nil, state: ItemState? = nil, allStates: Bool = false, tags: [String] = []) {
        self.type = type
        self.state = state
        self.allStates = allStates
        self.tags = tags
    }

    var core: CoreSearchFilters {
        CoreSearchFilters(state: state, allStates: allStates, type: type, tags: tags)
    }
}
