import Foundation
import MarfaCore
import MarfaCoreNames

public enum Tier: Sendable, Hashable, CaseIterable {
    case library
    case feed

    init(_ core: CoreTier) {
        switch core {
        case .library: self = .library
        case .feed: self = .feed
        }
    }

    var core: CoreTier {
        switch self {
        case .library: .library
        case .feed: .feed
        }
    }
}

public enum ItemState: Sendable, Hashable, CaseIterable {
    case active
    case archived
    case trashed
    case revoked

    init(_ core: CoreItemState) {
        switch core {
        case .active: self = .active
        case .archived: self = .archived
        case .trashed: self = .trashed
        case .revoked: self = .revoked
        }
    }

    var core: CoreItemState {
        switch self {
        case .active: .active
        case .archived: .archived
        case .trashed: .trashed
        case .revoked: .revoked
        }
    }
}

public enum WriteKind: Sendable, Hashable, CaseIterable {
    case createItem
    case updateItem
    case deleteItem
    case restoreItem
    case transitionItem
    case createEdge
    case updateEdge
    case deleteEdge
    case replaceMetadata
    case mergeMetadata
    case addTag
    case removeTag
    case writeExtension
    case deleteExtension
    case uploadBlob

    init(_ core: CoreWriteKind) {
        switch core {
        case .createItem: self = .createItem
        case .updateItem: self = .updateItem
        case .deleteItem: self = .deleteItem
        case .restoreItem: self = .restoreItem
        case .transitionItem: self = .transitionItem
        case .createEdge: self = .createEdge
        case .updateEdge: self = .updateEdge
        case .deleteEdge: self = .deleteEdge
        case .replaceMetadata: self = .replaceMetadata
        case .mergeMetadata: self = .mergeMetadata
        case .addTag: self = .addTag
        case .removeTag: self = .removeTag
        case .writeExtension: self = .writeExtension
        case .deleteExtension: self = .deleteExtension
        case .uploadBlob: self = .uploadBlob
        }
    }

    var core: CoreWriteKind {
        switch self {
        case .createItem: .createItem
        case .updateItem: .updateItem
        case .deleteItem: .deleteItem
        case .restoreItem: .restoreItem
        case .transitionItem: .transitionItem
        case .createEdge: .createEdge
        case .updateEdge: .updateEdge
        case .deleteEdge: .deleteEdge
        case .replaceMetadata: .replaceMetadata
        case .mergeMetadata: .mergeMetadata
        case .addTag: .addTag
        case .removeTag: .removeTag
        case .writeExtension: .writeExtension
        case .deleteExtension: .deleteExtension
        case .uploadBlob: .uploadBlob
        }
    }
}

/// Why a write is held back rather than sent or refused.
public enum BlockedReason: Sendable, Hashable, CaseIterable {
    case credentialRefused
    case keySpent
    case ancestorUnavailable
    case conflictUnresolved
    case awaitingDependency

    init(_ core: CoreBlockedReason) {
        switch core {
        case .credentialRefused: self = .credentialRefused
        case .keySpent: self = .keySpent
        case .ancestorUnavailable: self = .ancestorUnavailable
        case .conflictUnresolved: self = .conflictUnresolved
        case .awaitingDependency: self = .awaitingDependency
        }
    }

    var core: CoreBlockedReason {
        switch self {
        case .credentialRefused: .credentialRefused
        case .keySpent: .keySpent
        case .ancestorUnavailable: .ancestorUnavailable
        case .conflictUnresolved: .conflictUnresolved
        case .awaitingDependency: .awaitingDependency
        }
    }
}

/// The server's answer to a queued write.
public enum Verdict: Sendable, Hashable {
    case accepted
    /// The server applied the write over changes made since, field by field.
    case merged(fields: [String])
    /// The server kept its own value and wrote the losing one to a sibling.
    case conflicted(siblingId: String, fields: [String])
    /// The server's code verbatim, or the sentence naming the write this one
    /// waited on where that write was refused.
    case refused(reason: String)
    case blocked(reason: BlockedReason)
    /// Refused until the ceiling; released by id. The row's `answer` holds
    /// the last answer it got.
    case dead

    init(_ core: CoreVerdict) {
        switch core {
        case .accepted: self = .accepted
        case .merged(let fields): self = .merged(fields: fields)
        case .conflicted(let siblingId, let fields): self = .conflicted(siblingId: siblingId, fields: fields)
        case .refused(let reason): self = .refused(reason: reason)
        case .blocked(let reason): self = .blocked(reason: BlockedReason(reason))
        case .dead: self = .dead
        }
    }

    var core: CoreVerdict {
        switch self {
        case .accepted: .accepted
        case .merged(let fields): .merged(fields: fields)
        case .conflicted(let siblingId, let fields): .conflicted(siblingId: siblingId, fields: fields)
        case .refused(let reason): .refused(reason: reason)
        case .blocked(let reason): .blocked(reason: reason.core)
        case .dead: .dead
        }
    }
}

/// Whether a working copy writes its store or only reads it.
public enum Handle: Sendable, Hashable, CaseIterable {
    case writer
    case reader

    init(_ core: CoreHandle) {
        switch core {
        case .writer: self = .writer
        case .reader: self = .reader
        }
    }

    var core: CoreHandle {
        switch self {
        case .writer: .writer
        case .reader: .reader
        }
    }
}

public enum Hydration: Sendable, Hashable, CaseIterable {
    case never
    case inProgress
    case complete
    case expired

    init(_ core: CoreHydration) {
        switch core {
        case .never: self = .never
        case .inProgress: self = .inProgress
        case .complete: self = .complete
        case .expired: self = .expired
        }
    }

    var core: CoreHydration {
        switch self {
        case .never: .never
        case .inProgress: .inProgress
        case .complete: .complete
        case .expired: .expired
        }
    }
}

public enum SortField: Sendable, Hashable, CaseIterable {
    case createdAt
    case updatedAt
    case occurredAt

    init(_ core: CoreSortField) {
        switch core {
        case .createdAt: self = .createdAt
        case .updatedAt: self = .updatedAt
        case .occurredAt: self = .occurredAt
        }
    }

    var core: CoreSortField {
        switch self {
        case .createdAt: .createdAt
        case .updatedAt: .updatedAt
        case .occurredAt: .occurredAt
        }
    }
}

public enum SortDirection: Sendable, Hashable, CaseIterable {
    case ascending
    case descending

    init(_ core: CoreSortDirection) {
        switch core {
        case .ascending: self = .ascending
        case .descending: self = .descending
        }
    }

    var core: CoreSortDirection {
        switch self {
        case .ascending: .ascending
        case .descending: .descending
        }
    }
}

public struct Sort: Sendable, Hashable {
    public var field: SortField
    public var direction: SortDirection

    public init(field: SortField, direction: SortDirection) {
        self.field = field
        self.direction = direction
    }

    init(_ core: CoreSort) {
        self.init(field: SortField(core.field), direction: SortDirection(core.direction))
    }

    var core: CoreSort { CoreSort(field: field.core, direction: direction.core) }
}

public struct QueuedWrite: Sendable, Hashable {
    public var id: String
    public var kind: WriteKind
    public var itemId: String?
    public var targetId: String?
    public var edgeId: String?
    public var namespace: String?
    public var tag: String?
    /// The blob an upload carries, by its hash.
    public var blob: String?
    public var baseVersion: Int64?
    public var idempotencyKey: String
    /// The writes this one cannot go without, and is refused with.
    public var dependsOn: [String]
    /// The write ahead of this one to the same row or edge, which it goes
    /// out after and is not refused with.
    public var follows: String?
    public var verdict: Verdict?
    /// The server's answer, whole, as it arrived.
    public var answer: String?
    public var refusals: Int64
    public var queuedAt: String
    public var answeredAt: String?

    public init(
        id: String, kind: WriteKind, itemId: String? = nil, targetId: String? = nil, edgeId: String? = nil,
        namespace: String? = nil, tag: String? = nil, blob: String? = nil, baseVersion: Int64? = nil,
        idempotencyKey: String, dependsOn: [String] = [], follows: String? = nil, verdict: Verdict? = nil,
        answer: String? = nil, refusals: Int64 = 0, queuedAt: String, answeredAt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.itemId = itemId
        self.targetId = targetId
        self.edgeId = edgeId
        self.namespace = namespace
        self.tag = tag
        self.blob = blob
        self.baseVersion = baseVersion
        self.idempotencyKey = idempotencyKey
        self.dependsOn = dependsOn
        self.follows = follows
        self.verdict = verdict
        self.answer = answer
        self.refusals = refusals
        self.queuedAt = queuedAt
        self.answeredAt = answeredAt
    }

    init(_ core: CoreQueuedWrite) {
        self.init(
            id: core.id, kind: WriteKind(core.kind), itemId: core.itemId, targetId: core.targetId,
            edgeId: core.edgeId, namespace: core.namespace, tag: core.tag, blob: core.blob,
            baseVersion: core.baseVersion, idempotencyKey: core.idempotencyKey, dependsOn: core.dependsOn,
            follows: core.follows, verdict: core.verdict.map(Verdict.init), answer: core.answer,
            refusals: core.refusals, queuedAt: core.queuedAt, answeredAt: core.answeredAt)
    }

    var core: CoreQueuedWrite {
        CoreQueuedWrite(
            id: id, kind: kind.core, itemId: itemId, targetId: targetId, edgeId: edgeId, namespace: namespace,
            tag: tag, blob: blob, baseVersion: baseVersion, idempotencyKey: idempotencyKey,
            dependsOn: dependsOn, follows: follows, verdict: verdict?.core, answer: answer, refusals: refusals,
            queuedAt: queuedAt, answeredAt: answeredAt)
    }
}

public struct DrainVerdict: Sendable, Hashable {
    public var id: String
    public var kind: WriteKind
    public var itemId: String?
    public var verdict: Verdict?
    public var refusals: Int64
    /// The server answered from its record of this idempotency key rather
    /// than writing again.
    public var replayed: Bool

    public init(
        id: String, kind: WriteKind, itemId: String? = nil, verdict: Verdict? = nil, refusals: Int64 = 0,
        replayed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.itemId = itemId
        self.verdict = verdict
        self.refusals = refusals
        self.replayed = replayed
    }

    init(_ core: CoreDrainVerdict) {
        self.init(
            id: core.id, kind: WriteKind(core.kind), itemId: core.itemId, verdict: core.verdict.map(Verdict.init),
            refusals: core.refusals, replayed: core.replayed)
    }

    var core: CoreDrainVerdict {
        CoreDrainVerdict(
            id: id, kind: kind.core, itemId: itemId, verdict: verdict?.core, refusals: refusals,
            replayed: replayed)
    }
}

public struct DrainReport: Sendable, Hashable {
    public var sent: UInt64
    public var held: UInt64
    public var verdicts: [DrainVerdict]
    /// Why the drain stopped before the queue was empty, where it did.
    public var stopped: String?
    /// The sources the server said this credential's key does not claim,
    /// where a create naming one was refused for it: every create naming
    /// one is blocked `credential_refused` until the key claims it.
    public var unclaimedSources: [String]
    public var retryAfterSeconds: UInt64?

    public init(
        sent: UInt64 = 0, held: UInt64 = 0, verdicts: [DrainVerdict] = [], stopped: String? = nil,
        unclaimedSources: [String] = [], retryAfterSeconds: UInt64? = nil
    ) {
        self.sent = sent
        self.held = held
        self.verdicts = verdicts
        self.stopped = stopped
        self.unclaimedSources = unclaimedSources
        self.retryAfterSeconds = retryAfterSeconds
    }

    init(_ core: CoreDrainReport) {
        self.init(
            sent: core.sent, held: core.held, verdicts: core.verdicts.map(DrainVerdict.init),
            stopped: core.stopped, unclaimedSources: core.unclaimedSources,
            retryAfterSeconds: core.retryAfterSeconds)
    }

    var core: CoreDrainReport {
        CoreDrainReport(
            sent: sent, held: held, verdicts: verdicts.map(\.core), stopped: stopped,
            unclaimedSources: unclaimedSources, retryAfterSeconds: retryAfterSeconds)
    }
}

public struct HydrateReport: Sendable, Hashable {
    public var types: [String]
    public var tier: Tier
    public var edgeTypes: [String]
    public var items: UInt64
    public var edges: UInt64
    public var pages: UInt64
    public var cursor: String

    public init(
        types: [String], tier: Tier, edgeTypes: [String], items: UInt64, edges: UInt64, pages: UInt64,
        cursor: String
    ) {
        self.types = types
        self.tier = tier
        self.edgeTypes = edgeTypes
        self.items = items
        self.edges = edges
        self.pages = pages
        self.cursor = cursor
    }

    init(_ core: CoreHydrateReport) {
        self.init(
            types: core.types, tier: Tier(core.tier), edgeTypes: core.edgeTypes, items: core.items,
            edges: core.edges, pages: core.pages, cursor: core.cursor)
    }

    var core: CoreHydrateReport {
        CoreHydrateReport(
            types: types, tier: tier.core, edgeTypes: edgeTypes, items: items, edges: edges, pages: pages,
            cursor: cursor)
    }
}

public struct CatchUpReport: Sendable, Hashable {
    public var applied: UInt64
    public var skipped: UInt64
    public var cursor: String
    public var reachedHead: Bool

    public init(applied: UInt64, skipped: UInt64, cursor: String, reachedHead: Bool) {
        self.applied = applied
        self.skipped = skipped
        self.cursor = cursor
        self.reachedHead = reachedHead
    }

    init(_ core: CoreCatchUpReport) {
        self.init(
            applied: core.applied, skipped: core.skipped, cursor: core.cursor, reachedHead: core.reachedHead)
    }

    var core: CoreCatchUpReport {
        CoreCatchUpReport(applied: applied, skipped: skipped, cursor: cursor, reachedHead: reachedHead)
    }
}

public struct Status: Sendable, Hashable {
    public var serverOrigin: String?
    public var sliceTypes: [String]
    public var sliceTier: Tier?
    public var sliceEdgeTypes: [String]
    public var pinned: [String]
    public var eventCursor: String?
    public var hydration: Hydration
    public var items: UInt64
    public var edges: UInt64

    public init(
        serverOrigin: String? = nil, sliceTypes: [String] = [], sliceTier: Tier? = nil,
        sliceEdgeTypes: [String] = [], pinned: [String] = [], eventCursor: String? = nil,
        hydration: Hydration = .never, items: UInt64 = 0, edges: UInt64 = 0
    ) {
        self.serverOrigin = serverOrigin
        self.sliceTypes = sliceTypes
        self.sliceTier = sliceTier
        self.sliceEdgeTypes = sliceEdgeTypes
        self.pinned = pinned
        self.eventCursor = eventCursor
        self.hydration = hydration
        self.items = items
        self.edges = edges
    }

    init(_ core: CoreStatus) {
        self.init(
            serverOrigin: core.serverOrigin, sliceTypes: core.sliceTypes, sliceTier: core.sliceTier.map(Tier.init),
            sliceEdgeTypes: core.sliceEdgeTypes, pinned: core.pinned, eventCursor: core.eventCursor,
            hydration: Hydration(core.hydration), items: core.items, edges: core.edges)
    }

    var core: CoreStatus {
        CoreStatus(
            serverOrigin: serverOrigin, sliceTypes: sliceTypes, sliceTier: sliceTier?.core,
            sliceEdgeTypes: sliceEdgeTypes, pinned: pinned, eventCursor: eventCursor, hydration: hydration.core,
            items: items, edges: edges)
    }
}

/// What an attachment's file item is made as; unset fields take the file's.
public struct Attachment: Sendable, Hashable {
    public var mimeType: String?
    public var title: String?
    public var type: String?
    public var tier: Tier?

    public init(mimeType: String? = nil, title: String? = nil, type: String? = nil, tier: Tier? = nil) {
        self.mimeType = mimeType
        self.title = title
        self.type = type
        self.tier = tier
    }

    var core: CoreAttachment {
        CoreAttachment(mimeType: mimeType, title: title, type: type, tier: tier?.core)
    }
}

public struct Attached: Sendable, Hashable {
    public var upload: QueuedWrite
    public var item: QueuedWrite
    public var edge: QueuedWrite

    public init(upload: QueuedWrite, item: QueuedWrite, edge: QueuedWrite) {
        self.upload = upload
        self.item = item
        self.edge = edge
    }

    init(_ core: CoreAttached) {
        self.init(upload: QueuedWrite(core.upload), item: QueuedWrite(core.item), edge: QueuedWrite(core.edge))
    }
}

public struct Thumbnail: Sendable, Hashable {
    public var mimeType: String
    public var bytes: Data

    public init(mimeType: String, bytes: Data) {
        self.mimeType = mimeType
        self.bytes = bytes
    }

    init(_ core: CoreThumbnail) {
        self.init(mimeType: core.mimeType, bytes: core.bytes)
    }
}
