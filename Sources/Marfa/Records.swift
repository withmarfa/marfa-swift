import Foundation
package import MarfaCore

/// An item as the copy holds it.
///
/// `properties` holds the item's properties in the order the server answers them, and is empty where
/// `unreadableProperties` says the stored properties could not be read.
public struct Item: Sendable, Hashable {
    public var id: String
    public var type: String
    /// The item's properties, in the order the server answers them.
    ///
    /// Empty where `unreadableProperties` is set.
    public var properties: JSONObject
    public var state: ItemState
    public var tier: Tier?
    public var version: Int64
    public var schemaVersion: Int64
    public var source: String
    public var sourceId: String?
    public var occurredAt: String
    public var createdAt: String
    public var updatedAt: String
    public var tags: [String]
    /// Where the item was captured, in degrees, as sent.
    public var captureLatitude: Double?
    public var captureLongitude: Double?
    /// When the item went to the bin; none outside it, and for a row an archive restored to the bin without the time.
    public var trashedAt: String?
    /// The text under the property the type's display hints name as its
    /// title, or `title` where they name none; none where that holds no
    /// string.
    public var title: String?
    /// The text under the property the type's display hints name as its
    /// body, or `body` where they name none; none where that holds no
    /// string.
    public var body: String?
    /// Why `properties` is empty where the copy holds the item but its stored properties cannot be read, such as a
    /// store written to by something else.
    ///
    /// Every other field is as the copy holds it. A hydration replaces the stored properties from the server.
    public var unreadableProperties: String?

    public init(
        id: String, type: String, properties: JSONObject, state: ItemState, tier: Tier?, version: Int64,
        schemaVersion: Int64, source: String, sourceId: String?, occurredAt: String, createdAt: String,
        updatedAt: String, tags: [String], captureLatitude: Double? = nil, captureLongitude: Double? = nil,
        trashedAt: String? = nil, title: String? = nil, body: String? = nil, unreadableProperties: String? = nil
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
        self.captureLatitude = captureLatitude
        self.captureLongitude = captureLongitude
        self.trashedAt = trashedAt
        self.title = title
        self.body = body
        self.unreadableProperties = unreadableProperties
    }

    package init(_ core: MarfaCore.Item) {
        id = core.id
        type = core.type
        properties = JSONObject(core.properties)
        state = ItemState(core.state)
        tier = core.tier.map(Tier.init)
        version = core.version
        schemaVersion = core.schemaVersion
        source = core.source
        sourceId = core.sourceId
        occurredAt = core.occurredAt
        createdAt = core.createdAt
        updatedAt = core.updatedAt
        tags = core.tags
        captureLatitude = core.captureLatitude
        captureLongitude = core.captureLongitude
        trashedAt = core.trashedAt
        title = core.title
        body = core.body
        unreadableProperties = core.unreadableProperties
    }

    package var core: MarfaCore.Item {
        MarfaCore.Item(
            id: id,
            type: type,
            properties: properties.core,
            state: state.core,
            tier: tier.map(\.core),
            version: version,
            schemaVersion: schemaVersion,
            source: source,
            sourceId: sourceId,
            occurredAt: occurredAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tags: tags,
            captureLatitude: captureLatitude,
            captureLongitude: captureLongitude,
            trashedAt: trashedAt,
            title: title,
            body: body,
            unreadableProperties: unreadableProperties
        )
    }
}

/// An edge as the copy holds it.
public struct Edge: Sendable, Hashable {
    public var id: String
    public var sourceId: String
    public var targetId: String
    public var edgeType: String
    /// Empty where `unreadableProperties` is set.
    public var properties: JSONObject
    public var version: Int64
    public var createdAt: String
    public var updatedAt: String
    /// Why `properties` is empty where the copy holds the edge but its stored
    /// properties cannot be read.
    public var unreadableProperties: String?

    public init(
        id: String, sourceId: String, targetId: String, edgeType: String, properties: JSONObject, version: Int64,
        createdAt: String, updatedAt: String, unreadableProperties: String? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.edgeType = edgeType
        self.properties = properties
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.unreadableProperties = unreadableProperties
    }

    package init(_ core: MarfaCore.Edge) {
        id = core.id
        sourceId = core.sourceId
        targetId = core.targetId
        edgeType = core.edgeType
        properties = JSONObject(core.properties)
        version = core.version
        createdAt = core.createdAt
        updatedAt = core.updatedAt
        unreadableProperties = core.unreadableProperties
    }

    package var core: MarfaCore.Edge {
        MarfaCore.Edge(
            id: id,
            sourceId: sourceId,
            targetId: targetId,
            edgeType: edgeType,
            properties: properties.core,
            version: version,
            createdAt: createdAt,
            updatedAt: updatedAt,
            unreadableProperties: unreadableProperties
        )
    }
}

/// A create, before it is queued.
///
/// The tags are queued as writes of their own. See the core's documentation of each field.
public struct Draft: Sendable, Hashable {
    public var type: String
    public var properties: JSONObject
    /// Each queued as a write of its own, waiting on the create.
    public var tags: [String]
    public var tier: Tier?
    /// The state to create it in; none is active. `revoked` is refused.
    public var state: ItemState?
    public var id: String?
    public var source: String?
    public var sourceId: String?
    public var occurredAt: String?
    /// Where it was captured, in degrees.
    ///
    /// Both or neither.
    public var captureLatitude: Double?
    public var captureLongitude: Double?
    /// Edge type to the ids of the items it points at.
    ///
    /// They are queued and sent with the create as one write: if the server refuses any, it makes none and the create
    /// stays in the queue as refused.
    public var edges: [String: [String]]
    /// The version this create is conditional on, where its natural key
    /// resolves a row the server holds.
    public var baseVersion: Int64?

    public init(
        type: String, properties: JSONObject = [:], tags: [String] = [], tier: Tier? = nil, state: ItemState? = nil,
        id: String? = nil, source: String? = nil, sourceId: String? = nil, occurredAt: String? = nil,
        captureLatitude: Double? = nil, captureLongitude: Double? = nil, edges: [String: [String]] = [:],
        baseVersion: Int64? = nil
    ) {
        self.type = type
        self.properties = properties
        self.tags = tags
        self.tier = tier
        self.state = state
        self.id = id
        self.source = source
        self.sourceId = sourceId
        self.occurredAt = occurredAt
        self.captureLatitude = captureLatitude
        self.captureLongitude = captureLongitude
        self.edges = edges
        self.baseVersion = baseVersion
    }

    package init(_ core: MarfaCore.Draft) {
        type = core.type
        properties = JSONObject(core.properties)
        tags = core.tags
        tier = core.tier.map(Tier.init)
        state = core.state.map(ItemState.init)
        id = core.id
        source = core.source
        sourceId = core.sourceId
        occurredAt = core.occurredAt
        captureLatitude = core.captureLatitude
        captureLongitude = core.captureLongitude
        edges = core.edges
        baseVersion = core.baseVersion
    }

    package var core: MarfaCore.Draft {
        MarfaCore.Draft(
            type: type,
            properties: properties.core,
            tags: tags,
            tier: tier.map(\.core),
            state: state.map(\.core),
            id: id,
            source: source,
            sourceId: sourceId,
            occurredAt: occurredAt,
            captureLatitude: captureLatitude,
            captureLongitude: captureLongitude,
            edges: edges,
            baseVersion: baseVersion
        )
    }
}

/// A change to an item, and the version it was read at.
public struct Edit: Sendable, Hashable {
    /// Whole field values; a device never merges inside a field.
    ///
    /// Unless `replaceProperties` is set, each property given replaces its value and the rest stay, and a `null`
    /// clears nothing: the server drops it, and so does the copy, so the property keeps its value.
    public var properties: JSONObject
    /// The properties are the item's whole properties: one left out is cleared.
    ///
    /// Sent at a version older than the one the copy holds, through ``Items/updateAsRead(_:_:)``, it is merged as a
    /// merge is.
    public var replaceProperties: Bool
    /// The version the change was made against.
    public var baseVersion: Int64
    /// The natural key to move the row to.
    public var sourceId: String?
    /// The type to move the row to, sent as the server's retype.
    ///
    /// The properties it ends up with are held to that type.
    public var type: String?
    /// The tier to move the row to.
    public var tier: Tier?
    /// When the item's content happened.
    public var occurredAt: String?
    /// Gives the item no time of its own again, so it is its creation time.
    ///
    /// Refused beside `occurredAt`.
    public var clearOccurredAt: Bool

    public init(
        properties: JSONObject = [:], replaceProperties: Bool = false, baseVersion: Int64, sourceId: String? = nil,
        type: String? = nil, tier: Tier? = nil, occurredAt: String? = nil, clearOccurredAt: Bool = false
    ) {
        self.properties = properties
        self.replaceProperties = replaceProperties
        self.baseVersion = baseVersion
        self.sourceId = sourceId
        self.type = type
        self.tier = tier
        self.occurredAt = occurredAt
        self.clearOccurredAt = clearOccurredAt
    }

    package init(_ core: MarfaCore.Edit) {
        properties = JSONObject(core.properties)
        replaceProperties = core.replaceProperties
        baseVersion = core.baseVersion
        sourceId = core.sourceId
        type = core.type
        tier = core.tier.map(Tier.init)
        occurredAt = core.occurredAt
        clearOccurredAt = core.clearOccurredAt
    }

    package var core: MarfaCore.Edit {
        MarfaCore.Edit(
            properties: properties.core,
            replaceProperties: replaceProperties,
            baseVersion: baseVersion,
            sourceId: sourceId,
            type: type,
            tier: tier.map(\.core),
            occurredAt: occurredAt,
            clearOccurredAt: clearOccurredAt
        )
    }
}

/// With `state` unset, a list answers active items only; `allStates` lifts that.
///
/// A named `state` beside `allStates` is refused `validation_error`.
///
/// `filter` is an expression in the server's listing grammar. Its `status_group` term selects items by the group of
/// the word their status field holds, as their own type declares it: `eq` and `neq` take a ``StatusGroup`` raw
/// value, and `exists` and `not_exists` take none. An item whose type has no status field, or that holds no word or
/// one its type does not declare, is in no group, so only `not_exists` selects it. The open items of every type
/// with a status field are `status_group neq "completed" AND status_group neq "canceled"`. Match a type's own word
/// with `properties.<field> eq`.
public struct ListFilters: Sendable, Hashable {
    /// The core's list of types, each with its subtree; `nil` narrows nothing.
    package var types: [String]?
    /// The core's list of states; `nil` is the active state unless `allStates` is set.
    package var states: [ItemState]?
    public var allStates: Bool
    public var tier: Tier?
    public var tags: [String]
    public var occurredAfter: String?
    public var occurredBefore: String?
    /// Only the items stamped with this source.
    public var source: String?
    /// Inclusive lower bound on the time the item was last changed.
    ///
    /// The list is then ordered by that time and id, oldest first; a `sort` whose field or direction names another
    /// order is refused `validation_error`.
    public var updatedAfter: String?
    /// Exclusive upper bound on the time the item was last changed.
    public var updatedBefore: String?
    /// An expression in the server's listing grammar, answered as the server answers `filter` and refused
    /// `validation_error` where it refuses it.
    ///
    /// A `backref` condition is refused `invalid`.
    public var filter: String?
    /// An item id: that item and every item it reaches along `parent-of`
    /// edges, as far as the copy holds them.
    public var beneath: String?
    public var limit: UInt32?
    public var offset: UInt32?

    /// The one type to narrow to, with its subtree; `nil` where none is named or the filter names several.
    public var type: String? {
        get { types.flatMap { $0.count == 1 ? $0[0] : nil } }
        set { types = newValue.map { [$0] } }
    }

    /// The one state to narrow to; `nil` where none is named or the filter names several.
    public var state: ItemState? {
        get { states.flatMap { $0.count == 1 ? $0[0] : nil } }
        set { states = newValue.map { [$0] } }
    }

    public init(
        type: String? = nil, state: ItemState? = nil, allStates: Bool = false, tier: Tier? = nil, tags: [String] = [],
        occurredAfter: String? = nil, occurredBefore: String? = nil, source: String? = nil, updatedAfter: String? = nil,
        updatedBefore: String? = nil, filter: String? = nil, beneath: String? = nil, limit: UInt32? = nil,
        offset: UInt32? = nil
    ) {
        types = type.map { [$0] }
        states = state.map { [$0] }
        self.allStates = allStates
        self.tier = tier
        self.tags = tags
        self.occurredAfter = occurredAfter
        self.occurredBefore = occurredBefore
        self.source = source
        self.updatedAfter = updatedAfter
        self.updatedBefore = updatedBefore
        self.filter = filter
        self.beneath = beneath
        self.limit = limit
        self.offset = offset
    }

    package init(_ core: MarfaCore.ListFilters) {
        types = core.types
        states = core.states?.map(ItemState.init)
        allStates = core.allStates
        tier = core.tier.map(Tier.init)
        tags = core.tags
        occurredAfter = core.occurredAfter
        occurredBefore = core.occurredBefore
        source = core.source
        updatedAfter = core.updatedAfter
        updatedBefore = core.updatedBefore
        filter = core.filter
        beneath = core.beneath
        limit = core.limit
        offset = core.offset
    }

    package var core: MarfaCore.ListFilters {
        MarfaCore.ListFilters(
            types: types,
            states: states?.map(\.core),
            allStates: allStates,
            tier: tier.map(\.core),
            tags: tags,
            occurredAfter: occurredAfter,
            occurredBefore: occurredBefore,
            source: source,
            updatedAfter: updatedAfter,
            updatedBefore: updatedBefore,
            filter: filter,
            beneath: beneath,
            limit: limit,
            offset: offset
        )
    }
}

/// `state` and `allStates` work as in ``ListFilters``. `type` includes its
/// subtree, and every tag given must be present.
public struct SearchFilters: Sendable, Hashable {
    /// The core's list of types, each with its subtree; `nil` narrows nothing.
    package var types: [String]?
    /// The core's list of states; `nil` is the active state unless `allStates` is set.
    package var states: [ItemState]?
    public var allStates: Bool
    /// One tier; none answers both.
    public var tier: Tier?
    public var tags: [String]
    /// Exclusive lower bound on the item's own time.
    ///
    /// Either end alone works.
    public var occurredAfter: String?
    /// Exclusive upper bound on the item's own time.
    public var occurredBefore: String?
    /// An expression in the server's listing grammar, answered as the server answers `filter` and refused
    /// `validation_error` where it refuses it.
    ///
    /// A `backref` condition is refused `invalid`.
    public var filter: String?
    /// An item id: that item and every item it reaches along `parent-of`
    /// edges, as far as the copy holds them.
    public var beneath: String?

    /// The one type to narrow to, with its subtree; `nil` where none is named or the filter names several.
    public var type: String? {
        get { types.flatMap { $0.count == 1 ? $0[0] : nil } }
        set { types = newValue.map { [$0] } }
    }

    /// The one state to narrow to; `nil` where none is named or the filter names several.
    public var state: ItemState? {
        get { states.flatMap { $0.count == 1 ? $0[0] : nil } }
        set { states = newValue.map { [$0] } }
    }

    public init(
        type: String? = nil, state: ItemState? = nil, allStates: Bool = false, tier: Tier? = nil, tags: [String] = [],
        occurredAfter: String? = nil, occurredBefore: String? = nil, filter: String? = nil, beneath: String? = nil
    ) {
        types = type.map { [$0] }
        states = state.map { [$0] }
        self.allStates = allStates
        self.tier = tier
        self.tags = tags
        self.occurredAfter = occurredAfter
        self.occurredBefore = occurredBefore
        self.filter = filter
        self.beneath = beneath
    }

    package init(_ core: MarfaCore.SearchFilters) {
        types = core.types
        states = core.states?.map(ItemState.init)
        allStates = core.allStates
        tier = core.tier.map(Tier.init)
        tags = core.tags
        occurredAfter = core.occurredAfter
        occurredBefore = core.occurredBefore
        filter = core.filter
        beneath = core.beneath
    }

    package var core: MarfaCore.SearchFilters {
        MarfaCore.SearchFilters(
            types: types,
            states: states?.map(\.core),
            allStates: allStates,
            tier: tier.map(\.core),
            tags: tags,
            occurredAfter: occurredAfter,
            occurredBefore: occurredBefore,
            filter: filter,
            beneath: beneath
        )
    }
}

/// A hit of a search, with the item it found.
public struct SearchHit: Sendable, Hashable {
    public var item: Item
    /// Higher is a better match.
    public var score: Double
    /// An excerpt as HTML: the text escaped and each match in `<mark>` tags.
    public var snippet: String

    public init(item: Item, score: Double, snippet: String) {
        self.item = item
        self.score = score
        self.snippet = snippet
    }

    package init(_ core: MarfaCore.SearchHit) {
        item = Item(core.item)
        score = core.score
        snippet = core.snippet
    }

    package var core: MarfaCore.SearchHit {
        MarfaCore.SearchHit(
            item: item.core,
            score: score,
            snippet: snippet
        )
    }
}

/// One page of the server's bin.
public struct BinPage: Sendable, Hashable {
    public var items: [Item]
    /// Where the next page starts; none on the last.
    public var nextCursor: String?

    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }

    package init(_ core: MarfaCore.BinPage) {
        items = core.items.map(Item.init)
        nextCursor = core.nextCursor
    }

    package var core: MarfaCore.BinPage {
        MarfaCore.BinPage(
            items: items.map(\.core),
            nextCursor: nextCursor
        )
    }
}

/// What one group of a view holds: its `key` and how many items are in it.
///
/// The key is the value the view groups by: a string, number or boolean, a bucket's first date as `YYYY-MM-DD`, an
/// item id for an edge group, or `null` for the items that have none. An item with two tags is in both tag groups.
public struct ViewGroup: Sendable, Hashable {
    public var key: JSONValue
    public var count: UInt64

    public init(key: JSONValue, count: UInt64) {
        self.key = key
        self.count = count
    }

    package init(_ core: MarfaCore.ViewGroup) {
        key = JSONValue(core.key)
        count = core.count
    }

    package var core: MarfaCore.ViewGroup {
        MarfaCore.ViewGroup(
            key: key.core,
            count: count
        )
    }
}

/// The cache of fetched files: its setting, the budget in force and the bytes held, and the attachments kept
/// outside the budget.
///
/// `heldUnreadable` and `volumeUnreadable` say why `held` or `budget` could not be worked out, and
/// `backupMarkFailure` why the files fetched last could not be kept out of backups.
public struct FileCache: Sendable, Hashable {
    /// What was chosen.
    public var setting: FileBudget
    /// The budget in force, in bytes; none while every file fetched is kept.
    public var budget: UInt64?
    /// The bytes of the files kept now; none where the cache could not be
    /// read.
    public var held: UInt64?
    /// Why `held` is unknown; none when it is known.
    public var heldUnreadable: String?
    /// The default budget is 2 GiB because the disk could not be read.
    public var volumeUnreadable: Bool
    /// Why the files fetched last could not be kept out of backups; none
    /// once a fetched file is marked.
    public var backupMarkFailure: String?
    /// The files attached to items the copy holds, which stay on the device
    /// outside the budget; none from the start of a hydration until one
    /// completes, for a folder's copy, and where the cache could not be read.
    public var attachments: KeptAttachments?

    public init(
        setting: FileBudget, budget: UInt64?, held: UInt64?, heldUnreadable: String?, volumeUnreadable: Bool,
        backupMarkFailure: String?, attachments: KeptAttachments?
    ) {
        self.setting = setting
        self.budget = budget
        self.held = held
        self.heldUnreadable = heldUnreadable
        self.volumeUnreadable = volumeUnreadable
        self.backupMarkFailure = backupMarkFailure
        self.attachments = attachments
    }

    package init(_ core: MarfaCore.FileCache) {
        setting = FileBudget(core.setting)
        budget = core.budget
        held = core.held
        heldUnreadable = core.heldUnreadable
        volumeUnreadable = core.volumeUnreadable
        backupMarkFailure = core.backupMarkFailure
        attachments = core.attachments.map(KeptAttachments.init)
    }

    package var core: MarfaCore.FileCache {
        MarfaCore.FileCache(
            setting: setting.core,
            budget: budget,
            held: held,
            heldUnreadable: heldUnreadable,
            volumeUnreadable: volumeUnreadable,
            backupMarkFailure: backupMarkFailure,
            attachments: attachments.map(\.core)
        )
    }
}

/// The files attached to items the copy holds, which stay on the device outside the file budget: how many are held
/// whole, and how many are not, by reason.
public struct KeptAttachments: Sendable, Hashable {
    /// The file items whose bytes the cache holds whole.
    public var held: UInt64
    /// Their bytes, counted once for files that share them.
    public var heldBytes: UInt64
    /// The bytes of partial files of attachments.
    public var partialBytes: UInt64
    /// The attachments whose bytes the cache does not hold whole.
    public var notHeld: UInt64
    /// The bytes they state, counted once for files that share them.
    public var notHeldBytes: UInt64
    public var notHeldByReason: [NotHeldAttachments]

    public init(
        held: UInt64, heldBytes: UInt64, partialBytes: UInt64, notHeld: UInt64, notHeldBytes: UInt64,
        notHeldByReason: [NotHeldAttachments]
    ) {
        self.held = held
        self.heldBytes = heldBytes
        self.partialBytes = partialBytes
        self.notHeld = notHeld
        self.notHeldBytes = notHeldBytes
        self.notHeldByReason = notHeldByReason
    }

    package init(_ core: MarfaCore.Attachments) {
        held = core.held
        heldBytes = core.heldBytes
        partialBytes = core.partialBytes
        notHeld = core.notHeld
        notHeldBytes = core.notHeldBytes
        notHeldByReason = core.notHeldByReason.map(NotHeldAttachments.init)
    }

    package var core: MarfaCore.Attachments {
        MarfaCore.Attachments(
            held: held,
            heldBytes: heldBytes,
            partialBytes: partialBytes,
            notHeld: notHeld,
            notHeldBytes: notHeldBytes,
            notHeldByReason: notHeldByReason.map(\.core)
        )
    }
}

/// The attachments whose bytes are not held for one reason, with the bytes they state.
public struct NotHeldAttachments: Sendable, Hashable {
    public var reason: NotHeldReason
    public var attachments: UInt64
    /// The bytes they state, counted once for files that share them.
    public var bytes: UInt64
    /// How many of them state no size, so add nothing to `bytes`.
    public var unstated: UInt64

    public init(reason: NotHeldReason, attachments: UInt64, bytes: UInt64, unstated: UInt64) {
        self.reason = reason
        self.attachments = attachments
        self.bytes = bytes
        self.unstated = unstated
    }

    package init(_ core: MarfaCore.NotHeld) {
        reason = NotHeldReason(core.reason)
        attachments = core.attachments
        bytes = core.bytes
        unstated = core.unstated
    }

    package var core: MarfaCore.NotHeld {
        MarfaCore.NotHeld(
            reason: reason.core,
            attachments: attachments,
            bytes: bytes,
            unstated: unstated
        )
    }
}

/// What a fetch of the attachments did.
public struct KeptFetch: Sendable, Hashable {
    /// The files whose bytes it fetched, counted once for files that share
    /// them.
    public var fetched: UInt64
    public var fetchedBytes: UInt64
    /// The attachments after it, as the state report gives them.
    public var attachments: KeptAttachments?

    public init(fetched: UInt64, fetchedBytes: UInt64, attachments: KeptAttachments?) {
        self.fetched = fetched
        self.fetchedBytes = fetchedBytes
        self.attachments = attachments
    }

    package init(_ core: MarfaCore.KeptFetch) {
        fetched = core.fetched
        fetchedBytes = core.fetchedBytes
        attachments = core.attachments.map(KeptAttachments.init)
    }

    package var core: MarfaCore.KeptFetch {
        MarfaCore.KeptFetch(
            fetched: fetched,
            fetchedBytes: fetchedBytes,
            attachments: attachments.map(\.core)
        )
    }
}

/// The tier an item is in: `library` for lasting material, `feed` for an
/// incoming stream.
public enum Tier: Sendable, Hashable, CaseIterable {
    case library
    case feed

    package init(_ core: MarfaCore.Tier) {
        switch core {
        case .library: self = .library
        case .feed: self = .feed
        }
    }

    package var core: MarfaCore.Tier {
        switch self {
        case .library: .library
        case .feed: .feed
        }
    }
}

/// Where an item is in its life: `active`, `archived`, `trashed` or `revoked`.
public enum ItemState: Sendable, Hashable, CaseIterable {
    case active
    case archived
    case trashed
    case revoked

    package init(_ core: MarfaCore.ItemState) {
        switch core {
        case .active: self = .active
        case .archived: self = .archived
        case .trashed: self = .trashed
        case .revoked: self = .revoked
        }
    }

    package var core: MarfaCore.ItemState {
        switch self {
        case .active: .active
        case .archived: .archived
        case .trashed: .trashed
        case .revoked: .revoked
        }
    }
}

/// Whether a read was answered from a whole copy; from one a hydration is still filling, which holds only the rows
/// that have arrived (`.partial`); or from one the server's event log no longer reaches, which holds the rows it
/// held then, some since changed or gone on the server, until a hydration has filled it again (`.stale`).
public enum Completeness: Sendable, Hashable, CaseIterable {
    case complete
    case partial
    case stale

    package init(_ core: MarfaCore.Completeness) {
        switch core {
        case .complete: self = .complete
        case .partial: self = .partial
        case .stale: self = .stale
        }
    }

    package var core: MarfaCore.Completeness {
        switch self {
        case .complete: .complete
        case .partial: .partial
        case .stale: .stale
        }
    }
}

/// How the cache of fetched files chooses its budget.
public enum FileBudget: Sendable, Hashable {
    /// The larger of 2 GiB and a tenth of the volume, held to what leaves a
    /// twentieth of the volume free.
    case `default`
    /// This many bytes.
    case bytes(bytes: UInt64)
    /// No budget: every file fetched stays.
    case keepAll

    package init(_ core: MarfaCore.FileBudget) {
        switch core {
        case .default: self = .`default`
        case .bytes(let bytes): self = .bytes(bytes: bytes)
        case .keepAll: self = .keepAll
        }
    }

    package var core: MarfaCore.FileBudget {
        switch self {
        case .`default`: .`default`
        case .bytes(let bytes): .bytes(bytes: bytes)
        case .keepAll: .keepAll
        }
    }
}

/// Why an attachment's bytes are not held.
public enum NotHeldReason: Sendable, Hashable, CaseIterable {
    /// No fetch of them has been asked for since they became an attachment.
    case notFetched
    /// The volume had no room for them, or for an attachment before them in
    /// the same fetch.
    case noRoom
    /// The server, or the link it gave, could not be reached, or the link
    /// stopped sending part way.
    case unreachable
    /// The server asked for a wait longer than a fetch of attachments
    /// makes, before them or an attachment before them in the same fetch.
    case rateLimited
    /// The server holds no bytes by that hash.
    case absent
    /// The fetch failed otherwise.
    case failed
    /// The edge is held but its file item is not.
    case notInCopy

    package init(_ core: MarfaCore.NotHeldReason) {
        switch core {
        case .notFetched: self = .notFetched
        case .noRoom: self = .noRoom
        case .unreachable: self = .unreachable
        case .rateLimited: self = .rateLimited
        case .absent: self = .absent
        case .failed: self = .failed
        case .notInCopy: self = .notInCopy
        }
    }

    package var core: MarfaCore.NotHeldReason {
        switch self {
        case .notFetched: .notFetched
        case .noRoom: .noRoom
        case .unreachable: .unreachable
        case .rateLimited: .rateLimited
        case .absent: .absent
        case .failed: .failed
        case .notInCopy: .notInCopy
        }
    }
}
