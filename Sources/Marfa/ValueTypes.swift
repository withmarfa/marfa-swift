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

/// Why a write is stopped until something outside the queue changes.
public enum BlockedReason: Sendable, Hashable, CaseIterable {
    case credentialRefused
    case keySpent
    case ancestorUnavailable
    case conflictUnresolved
    /// Never a verdict's reason, here only because the core still lists it.
    /// A write held behind another has no verdict and `QueuedWrite.waiting`
    /// set instead.
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
///
/// A write the queue holds behind another that has no answer yet has no
/// verdict: `QueuedWrite.waiting` says so. `blocked` is a write stopped until
/// something outside the queue changes, which an app may need to act on.
public enum Verdict: Sendable, Hashable {
    case accepted
    /// The server applied the write over changes made since, field by field.
    case merged(fields: [String])
    /// The server kept its own value and wrote the losing one to a sibling.
    case conflicted(siblingId: String, fields: [String])
    case refused(Refusal)
    case blocked(reason: BlockedReason)
    /// Refused until the ceiling; released by id. The row's `answer` holds
    /// the last answer it got.
    case dead

    init(_ core: CoreVerdict) {
        switch core {
        case .accepted: self = .accepted
        case .merged(let fields): self = .merged(fields: fields)
        case .conflicted(let siblingId, let fields): self = .conflicted(siblingId: siblingId, fields: fields)
        case .refused(let refusal): self = .refused(Refusal(refusal))
        case .blocked(let reason): self = .blocked(reason: BlockedReason(reason))
        case .dead: self = .dead
        }
    }

    var core: CoreVerdict {
        switch self {
        case .accepted: .accepted
        case .merged(let fields): .merged(fields: fields)
        case .conflicted(let siblingId, let fields): .conflicted(siblingId: siblingId, fields: fields)
        case .refused(let refusal): .refused(refusal: refusal.core)
        case .blocked(let reason): .blocked(reason: reason.core)
        case .dead: .dead
        }
    }
}

/// Why the server, or the drain for a write it never sent, refused a write.
public struct Refusal: Sendable, Hashable {
    /// The server's code verbatim, or the sentence naming the write this one
    /// waited on where that write was refused.
    public var reason: String
    /// The code in the server's envelope, where the server refused it.
    public var code: String?
    public var message: String?
    /// Each property the server would not take, and why.
    public var fields: [FieldRefusal]
    /// The row the write named is in the bin, and can be restored.
    public var trashed: Bool
    /// The permission the credential's key lacks, where the refusal names one.
    public var grant: MissingGrant?

    public init(
        reason: String, code: String? = nil, message: String? = nil, fields: [FieldRefusal] = [],
        trashed: Bool = false, grant: MissingGrant? = nil
    ) {
        self.reason = reason
        self.code = code
        self.message = message
        self.fields = fields
        self.trashed = trashed
        self.grant = grant
    }

    init(_ core: CoreRefusal) {
        self.init(
            reason: core.reason, code: core.code, message: core.message,
            fields: core.fields.map { FieldRefusal(field: $0.field, message: $0.message) }, trashed: core.trashed,
            grant: core.grant.map(MissingGrant.init))
    }

    var core: CoreRefusal {
        CoreRefusal(
            reason: reason, code: code, message: message,
            fields: fields.map { CoreFieldRefusal(field: $0.field, message: $0.message) }, trashed: trashed,
            grant: grant?.core)
    }
}

public struct FieldRefusal: Sendable, Hashable {
    public var field: String
    public var message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

public struct MissingGrant: Sendable, Hashable {
    public var kind: GrantKind
    /// The type or edge type id, or the extension namespace.
    public var name: String
    public var level: GrantLevel

    public init(kind: GrantKind, name: String, level: GrantLevel) {
        self.kind = kind
        self.name = name
        self.level = level
    }

    init(_ core: CoreMissingGrant) {
        self.init(kind: GrantKind(core.kind), name: core.name, level: GrantLevel(core.level))
    }

    var core: CoreMissingGrant { CoreMissingGrant(kind: kind.core, name: name, level: level.core) }
}

public enum GrantKind: Sendable, Hashable, CaseIterable {
    case type
    case edgeType
    case `extension`

    init(_ core: CoreGrantKind) {
        switch core {
        case .type: self = .type
        case .edgeType: self = .edgeType
        case .extension: self = .extension
        }
    }

    var core: CoreGrantKind {
        switch self {
        case .type: .type
        case .edgeType: .edgeType
        case .extension: .extension
        }
    }
}

public enum GrantLevel: Sendable, Hashable, CaseIterable {
    case read
    case write

    init(_ core: CoreGrantLevel) {
        switch core {
        case .read: self = .read
        case .write: self = .write
        }
    }

    var core: CoreGrantLevel {
        switch self {
        case .read: .read
        case .write: .write
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
    /// `nil` while the server has not answered it.
    public var verdict: Verdict?
    /// Held behind a write that has no answer yet, named in `dependsOn` or
    /// `follows`; it goes once that write is answered, with nothing for the
    /// app to do, and has no verdict meanwhile.
    public var waiting: Bool
    /// What the write sends, or sent; a refused write that carried content
    /// keeps it here, through `forgetAnswered()`, until `discard(_:)`.
    public var body: [String: JSONValue]
    /// The server's answer, whole, as it arrived.
    public var answer: String?
    public var refusals: Int64
    public var queuedAt: String
    public var answeredAt: String?

    public init(
        id: String, kind: WriteKind, itemId: String? = nil, targetId: String? = nil, edgeId: String? = nil,
        namespace: String? = nil, tag: String? = nil, blob: String? = nil, baseVersion: Int64? = nil,
        idempotencyKey: String, dependsOn: [String] = [], follows: String? = nil, verdict: Verdict? = nil,
        waiting: Bool = false, body: [String: JSONValue] = [:], answer: String? = nil, refusals: Int64 = 0,
        queuedAt: String, answeredAt: String? = nil
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
        self.waiting = waiting
        self.body = body
        self.answer = answer
        self.refusals = refusals
        self.queuedAt = queuedAt
        self.answeredAt = answeredAt
    }

    init(_ core: CoreQueuedWrite) throws {
        self.init(
            id: core.id, kind: WriteKind(core.kind), itemId: core.itemId, targetId: core.targetId,
            edgeId: core.edgeId, namespace: core.namespace, tag: core.tag, blob: core.blob,
            baseVersion: core.baseVersion, idempotencyKey: core.idempotencyKey, dependsOn: core.dependsOn,
            follows: core.follows, verdict: core.verdict.map(Verdict.init), waiting: core.waiting,
            body: try Properties.object(core.bodyJson), answer: core.answer, refusals: core.refusals,
            queuedAt: core.queuedAt, answeredAt: core.answeredAt)
    }

    func core() throws -> CoreQueuedWrite {
        CoreQueuedWrite(
            id: id, kind: kind.core, itemId: itemId, targetId: targetId, edgeId: edgeId, namespace: namespace,
            tag: tag, blob: blob, baseVersion: baseVersion, idempotencyKey: idempotencyKey,
            dependsOn: dependsOn, follows: follows, verdict: verdict?.core, waiting: waiting,
            bodyJson: try Properties.text(body), answer: answer, refusals: refusals, queuedAt: queuedAt,
            answeredAt: answeredAt)
    }
}

/// What became of one write a drain answered, sent or not.
public struct DrainVerdict: Sendable, Hashable {
    public var id: String
    public var kind: WriteKind
    /// An edge write's source; otherwise the row written to.
    public var itemId: String?
    public var edgeId: String?
    public var verdict: Verdict?
    public var refusals: Int64
    /// The server answered from its record of this idempotency key rather
    /// than writing again.
    public var replayed: Bool

    public init(
        id: String, kind: WriteKind, itemId: String? = nil, edgeId: String? = nil, verdict: Verdict? = nil,
        refusals: Int64 = 0, replayed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.itemId = itemId
        self.edgeId = edgeId
        self.verdict = verdict
        self.refusals = refusals
        self.replayed = replayed
    }

    init(_ core: CoreDrainVerdict) {
        self.init(
            id: core.id, kind: WriteKind(core.kind), itemId: core.itemId, edgeId: core.edgeId,
            verdict: core.verdict.map(Verdict.init), refusals: core.refusals, replayed: core.replayed)
    }

    var core: CoreDrainVerdict {
        CoreDrainVerdict(
            id: id, kind: kind.core, itemId: itemId, edgeId: edgeId, verdict: verdict?.core, refusals: refusals,
            replayed: replayed)
    }
}

public struct DrainReport: Sendable, Hashable {
    /// Writes whose requests the server answered, whatever the answer was.
    public var answered: UInt64
    public var held: UInt64
    /// Writes that could not reach the server, still waiting and uncounted.
    public var undelivered: UInt64
    /// Writes settled without sending a request.
    public var unsent: UInt64
    /// Requests that could not be made, counted against their queued write.
    public var unmade: UInt64
    /// Why the drain ended before the queue was through.
    public var unavailable: String?
    /// Each settled write; a held change stream is told every verdict.
    public var verdicts: [DrainVerdict]
    /// The credential refusal that parked the queue, where one did.
    public var stopped: String?
    public var unclaimedSources: [String]
    public var retryAfterSeconds: UInt64?

    public init(
        answered: UInt64 = 0, held: UInt64 = 0, undelivered: UInt64 = 0, unsent: UInt64 = 0,
        unmade: UInt64 = 0, unavailable: String? = nil, verdicts: [DrainVerdict] = [], stopped: String? = nil,
        unclaimedSources: [String] = [], retryAfterSeconds: UInt64? = nil
    ) {
        self.answered = answered
        self.held = held
        self.undelivered = undelivered
        self.unsent = unsent
        self.unmade = unmade
        self.unavailable = unavailable
        self.verdicts = verdicts
        self.stopped = stopped
        self.unclaimedSources = unclaimedSources
        self.retryAfterSeconds = retryAfterSeconds
    }

    init(_ core: CoreDrainReport) {
        self.init(
            answered: core.answered, held: core.held, undelivered: core.undelivered, unsent: core.unsent,
            unmade: core.unmade, unavailable: core.unavailable, verdicts: core.verdicts.map(DrainVerdict.init),
            stopped: core.stopped, unclaimedSources: core.unclaimedSources,
            retryAfterSeconds: core.retryAfterSeconds)
    }

    var core: CoreDrainReport {
        CoreDrainReport(
            answered: answered, held: held, undelivered: undelivered, unsent: unsent, unmade: unmade,
            unavailable: unavailable, verdicts: verdicts.map(\.core), stopped: stopped,
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

public struct PinReport: Sendable, Hashable {
    public var pinned: Bool
    public var wasPinned: Bool

    public init(pinned: Bool, wasPinned: Bool) {
        self.pinned = pinned
        self.wasPinned = wasPinned
    }

    init(_ core: CorePinReport) {
        self.init(pinned: core.pinned, wasPinned: core.wasPinned)
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
    public var instanceId: String?
    public var sliceTypes: [String]
    public var sliceTier: Tier?
    public var sliceEdgeTypes: [String]
    public var pinned: [String]
    public var eventCursor: String?
    public var hydration: Hydration
    public var items: UInt64
    public var edges: UInt64
    /// Moves each time a refresh changes the item type or edge type catalog,
    /// and at no other time; `nil` until the copy first holds a catalog.
    public var catalogVersion: UInt64?

    public init(
        serverOrigin: String? = nil, sliceTypes: [String] = [], sliceTier: Tier? = nil,
        sliceEdgeTypes: [String] = [], pinned: [String] = [], eventCursor: String? = nil,
        hydration: Hydration = .never, items: UInt64 = 0, edges: UInt64 = 0, catalogVersion: UInt64? = nil,
        instanceId: String? = nil
    ) {
        self.serverOrigin = serverOrigin
        self.instanceId = instanceId
        self.sliceTypes = sliceTypes
        self.sliceTier = sliceTier
        self.sliceEdgeTypes = sliceEdgeTypes
        self.pinned = pinned
        self.eventCursor = eventCursor
        self.hydration = hydration
        self.items = items
        self.edges = edges
        self.catalogVersion = catalogVersion
    }

    init(_ core: CoreStatus) {
        self.init(
            serverOrigin: core.serverOrigin, sliceTypes: core.sliceTypes, sliceTier: core.sliceTier.map(Tier.init),
            sliceEdgeTypes: core.sliceEdgeTypes, pinned: core.pinned, eventCursor: core.eventCursor,
            hydration: Hydration(core.hydration), items: core.items, edges: core.edges,
            catalogVersion: core.catalogVersion, instanceId: core.instanceId)
    }

    var core: CoreStatus {
        CoreStatus(
            serverOrigin: serverOrigin, instanceId: instanceId, sliceTypes: sliceTypes, sliceTier: sliceTier?.core,
            sliceEdgeTypes: sliceEdgeTypes, pinned: pinned, eventCursor: eventCursor, hydration: hydration.core,
            items: items, edges: edges, catalogVersion: catalogVersion)
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

    init(_ core: CoreAttached) throws {
        self.init(
            upload: try QueuedWrite(core.upload), item: try QueuedWrite(core.item), edge: try QueuedWrite(core.edge))
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
