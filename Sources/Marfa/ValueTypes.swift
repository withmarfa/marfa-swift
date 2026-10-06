import Foundation
import MarfaCore

public enum Tier: Sendable, Hashable, CaseIterable {
    case library
    case feed

    init(_ core: MarfaCore.Tier) {
        switch core {
        case .library: self = .library
        case .feed: self = .feed
        }
    }

    var core: MarfaCore.Tier {
        switch self {
        case .library: .library
        case .feed: .feed
        }
    }
}

/// The tiers a working copy's slice holds: one ``Tier``, or both.
///
/// An item is in exactly one tier, so an item's `tier` is a ``Tier``. A slice
/// of both keeps an item whose tier moves, so an inbox at `feed` and the record
/// at `library` can be read from one copy, offline as well.
public enum SliceTier: Sendable, Hashable, CaseIterable {
    case library
    case feed
    /// Both tiers. A create that names no tier is sent and shown at `library`.
    case all

    public init(_ tier: Tier) {
        switch tier {
        case .library: self = .library
        case .feed: self = .feed
        }
    }

    init(_ core: MarfaCore.SliceTier) {
        switch core {
        case .library: self = .library
        case .feed: self = .feed
        case .all: self = .all
        }
    }

    var core: MarfaCore.SliceTier {
        switch self {
        case .library: .library
        case .feed: .feed
        case .all: .all
        }
    }
}

public enum ItemState: Sendable, Hashable, CaseIterable {
    case active
    case archived
    case trashed
    case revoked

    init(_ core: MarfaCore.ItemState) {
        switch core {
        case .active: self = .active
        case .archived: self = .archived
        case .trashed: self = .trashed
        case .revoked: self = .revoked
        }
    }

    var core: MarfaCore.ItemState {
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

    init(_ core: MarfaCore.WriteKind) {
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

    var core: MarfaCore.WriteKind {
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

    init(_ core: MarfaCore.BlockedReason) {
        switch core {
        case .credentialRefused: self = .credentialRefused
        case .keySpent: self = .keySpent
        case .ancestorUnavailable: self = .ancestorUnavailable
        case .conflictUnresolved: self = .conflictUnresolved
        case .awaitingDependency: self = .awaitingDependency
        }
    }

    var core: MarfaCore.BlockedReason {
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
    case blocked(reason: BlockedReason, refusal: Refusal? = nil)
    /// Refused until the ceiling; released by id. The row's `answer` holds
    /// the last answer it got.
    case dead

    init(_ core: MarfaCore.Verdict) {
        switch core {
        case .accepted: self = .accepted
        case .merged(let fields): self = .merged(fields: fields)
        case .conflicted(let siblingId, let fields): self = .conflicted(siblingId: siblingId, fields: fields)
        case .refused(let refusal): self = .refused(Refusal(refusal))
        case .blocked(let reason, let refusal):
            self = .blocked(reason: BlockedReason(reason), refusal: refusal.map(Refusal.init))
        case .dead: self = .dead
        }
    }

    var core: MarfaCore.Verdict {
        switch self {
        case .accepted: .accepted
        case .merged(let fields): .merged(fields: fields)
        case .conflicted(let siblingId, let fields): .conflicted(siblingId: siblingId, fields: fields)
        case .refused(let refusal): .refused(refusal: refusal.core)
        case .blocked(let reason, let refusal): .blocked(reason: reason.core, refusal: refusal?.core)
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

    init(_ core: MarfaCore.Refusal) {
        self.init(
            reason: core.reason, code: core.code, message: core.message,
            fields: core.fields.map { FieldRefusal(field: $0.field, message: $0.message) }, trashed: core.trashed,
            grant: core.grant.map(MissingGrant.init))
    }

    var core: MarfaCore.Refusal {
        MarfaCore.Refusal(
            reason: reason, code: code, message: message,
            fields: fields.map { MarfaCore.FieldRefusal(field: $0.field, message: $0.message) }, trashed: trashed,
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

    init(_ core: MarfaCore.MissingGrant) {
        self.init(kind: GrantKind(core.kind), name: core.name, level: GrantLevel(core.level))
    }

    var core: MarfaCore.MissingGrant { MarfaCore.MissingGrant(kind: kind.core, name: name, level: level.core) }
}

public enum GrantKind: Sendable, Hashable, CaseIterable {
    case type
    case edgeType
    case `extension`

    init(_ core: MarfaCore.GrantKind) {
        switch core {
        case .type: self = .type
        case .edgeType: self = .edgeType
        case .extension: self = .extension
        }
    }

    var core: MarfaCore.GrantKind {
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

    init(_ core: MarfaCore.GrantLevel) {
        switch core {
        case .read: self = .read
        case .write: self = .write
        }
    }

    var core: MarfaCore.GrantLevel {
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

    init(_ core: MarfaCore.Handle) {
        switch core {
        case .writer: self = .writer
        case .reader: self = .reader
        }
    }

    var core: MarfaCore.Handle {
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

    init(_ core: MarfaCore.Hydration) {
        switch core {
        case .never: self = .never
        case .inProgress: self = .inProgress
        case .complete: self = .complete
        case .expired: self = .expired
        }
    }

    var core: MarfaCore.Hydration {
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

    init(_ core: MarfaCore.SortField) {
        switch core {
        case .createdAt: self = .createdAt
        case .updatedAt: self = .updatedAt
        case .occurredAt: self = .occurredAt
        }
    }

    var core: MarfaCore.SortField {
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

    init(_ core: MarfaCore.SortDirection) {
        switch core {
        case .ascending: self = .ascending
        case .descending: self = .descending
        }
    }

    var core: MarfaCore.SortDirection {
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

    init(_ core: MarfaCore.Sort) {
        self.init(field: SortField(core.field), direction: SortDirection(core.direction))
    }

    var core: MarfaCore.Sort { MarfaCore.Sort(field: field.core, direction: direction.core) }
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
    public var body: JSONObject
    /// The server's answer, whole, as it arrived.
    public var answer: String?
    public var refusals: Int64
    public var queuedAt: String
    public var answeredAt: String?

    public init(
        id: String, kind: WriteKind, itemId: String? = nil, targetId: String? = nil, edgeId: String? = nil,
        namespace: String? = nil, tag: String? = nil, blob: String? = nil, baseVersion: Int64? = nil,
        idempotencyKey: String, dependsOn: [String] = [], follows: String? = nil, verdict: Verdict? = nil,
        waiting: Bool = false, body: JSONObject = [:], answer: String? = nil, refusals: Int64 = 0,
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

    init(_ core: MarfaCore.QueuedWrite) throws {
        self.init(
            id: core.id, kind: WriteKind(core.kind), itemId: core.itemId, targetId: core.targetId,
            edgeId: core.edgeId, namespace: core.namespace, tag: core.tag, blob: core.blob,
            baseVersion: core.baseVersion, idempotencyKey: core.idempotencyKey, dependsOn: core.dependsOn,
            follows: core.follows, verdict: core.verdict.map(Verdict.init), waiting: core.waiting,
            body: try JSONObject(json: core.bodyJson), answer: core.answer, refusals: core.refusals,
            queuedAt: core.queuedAt, answeredAt: core.answeredAt)
    }

    func core() throws -> MarfaCore.QueuedWrite {
        MarfaCore.QueuedWrite(
            id: id, kind: kind.core, itemId: itemId, targetId: targetId, edgeId: edgeId, namespace: namespace,
            tag: tag, blob: blob, baseVersion: baseVersion, idempotencyKey: idempotencyKey,
            dependsOn: dependsOn, follows: follows, verdict: verdict?.core, waiting: waiting,
            bodyJson: try body.json(), answer: answer, refusals: refusals, queuedAt: queuedAt,
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

    init(_ core: MarfaCore.DrainVerdict) {
        self.init(
            id: core.id, kind: WriteKind(core.kind), itemId: core.itemId, edgeId: core.edgeId,
            verdict: core.verdict.map(Verdict.init), refusals: core.refusals, replayed: core.replayed)
    }

    var core: MarfaCore.DrainVerdict {
        MarfaCore.DrainVerdict(
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
    /// Writes attempted or settled; unanswered entries have no verdict.
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

    init(_ core: MarfaCore.DrainReport) {
        self.init(
            answered: core.answered, held: core.held, undelivered: core.undelivered, unsent: core.unsent,
            unmade: core.unmade, unavailable: core.unavailable, verdicts: core.verdicts.map(DrainVerdict.init),
            stopped: core.stopped, unclaimedSources: core.unclaimedSources,
            retryAfterSeconds: core.retryAfterSeconds)
    }

    var core: MarfaCore.DrainReport {
        MarfaCore.DrainReport(
            answered: answered, held: held, undelivered: undelivered, unsent: unsent, unmade: unmade,
            unavailable: unavailable, verdicts: verdicts.map(\.core), stopped: stopped,
            unclaimedSources: unclaimedSources, retryAfterSeconds: retryAfterSeconds)
    }
}

/// A declared type the instance refused to register during hydration.
public struct UnregisteredType: Sendable, Hashable, Identifiable {
    public var id: String
    public var code: String
    public var message: String

    public init(id: String, code: String, message: String) {
        self.id = id
        self.code = code
        self.message = message
    }

    init(_ core: MarfaCore.UnregisteredType) {
        self.init(id: core.id, code: core.code, message: core.message)
    }

    var core: MarfaCore.UnregisteredType {
        MarfaCore.UnregisteredType(id: id, code: code, message: message)
    }
}

public struct HydrateReport: Sendable, Hashable {
    public var types: [String]
    public var tier: SliceTier
    public var edgeTypes: [String]
    public var items: UInt64
    public var edges: UInt64
    public var pages: UInt64
    public var cursor: String
    public var registeredTypes: [String]
    public var unregisteredTypes: [UnregisteredType]

    public init(
        types: [String], tier: SliceTier, edgeTypes: [String], items: UInt64, edges: UInt64, pages: UInt64,
        cursor: String, registeredTypes: [String] = [], unregisteredTypes: [UnregisteredType] = []
    ) {
        self.types = types
        self.tier = tier
        self.edgeTypes = edgeTypes
        self.items = items
        self.edges = edges
        self.pages = pages
        self.cursor = cursor
        self.registeredTypes = registeredTypes
        self.unregisteredTypes = unregisteredTypes
    }

    init(_ core: MarfaCore.HydrateReport) {
        self.init(
            types: core.types, tier: SliceTier(core.tier), edgeTypes: core.edgeTypes, items: core.items,
            edges: core.edges, pages: core.pages, cursor: core.cursor,
            registeredTypes: core.registeredTypes, unregisteredTypes: core.unregisteredTypes.map(UnregisteredType.init))
    }

    var core: MarfaCore.HydrateReport {
        MarfaCore.HydrateReport(
            types: types, tier: tier.core, edgeTypes: edgeTypes, items: items, edges: edges, pages: pages,
            cursor: cursor, registeredTypes: registeredTypes, unregisteredTypes: unregisteredTypes.map(\.core))
    }
}

public struct PinReport: Sendable, Hashable {
    public var pinned: Bool
    public var wasPinned: Bool

    public init(pinned: Bool, wasPinned: Bool) {
        self.pinned = pinned
        self.wasPinned = wasPinned
    }

    init(_ core: MarfaCore.PinReport) {
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

    init(_ core: MarfaCore.CatchUpReport) {
        self.init(
            applied: core.applied, skipped: core.skipped, cursor: core.cursor, reachedHead: core.reachedHead)
    }

    var core: MarfaCore.CatchUpReport {
        MarfaCore.CatchUpReport(applied: applied, skipped: skipped, cursor: cursor, reachedHead: reachedHead)
    }
}

public struct Status: Sendable, Hashable {
    public var serverOrigin: String?
    public var instanceId: String?
    public var sliceTypes: [String]
    public var sliceTier: SliceTier?
    public var sliceEdgeTypes: [String]
    public var pinned: [String]
    public var eventCursor: String?
    public var hydration: Hydration
    public var items: UInt64
    public var edges: UInt64
    /// Moves each time a refresh changes the server's item type or edge type
    /// catalog; `nil` until the copy first holds the server's catalog.
    ///
    /// Local built-in and declared types do not assign a version.
    public var catalogVersion: UInt64?

    public init(
        serverOrigin: String? = nil, sliceTypes: [String] = [], sliceTier: SliceTier? = nil,
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

    init(_ core: MarfaCore.Status) {
        self.init(
            serverOrigin: core.serverOrigin, sliceTypes: core.sliceTypes, sliceTier: core.sliceTier.map(SliceTier.init),
            sliceEdgeTypes: core.sliceEdgeTypes, pinned: core.pinned, eventCursor: core.eventCursor,
            hydration: Hydration(core.hydration), items: core.items, edges: core.edges,
            catalogVersion: core.catalogVersion, instanceId: core.instanceId)
    }

    var core: MarfaCore.Status {
        MarfaCore.Status(
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

    var core: MarfaCore.Attachment {
        MarfaCore.Attachment(mimeType: mimeType, title: title, type: type, tier: tier?.core)
    }
}

public struct Attached: Sendable, Hashable {
    public var upload: QueuedWrite
    public var item: QueuedWrite
    public var edge: QueuedWrite
    /// The text that embeds the file in the item's body, `![[title]]`, which
    /// the body reads back as `edge` and not as a second one; `nil` where the
    /// file's title cannot name it alone in an embed.
    public var embed: String?

    public init(upload: QueuedWrite, item: QueuedWrite, edge: QueuedWrite, embed: String? = nil) {
        self.upload = upload
        self.item = item
        self.edge = edge
        self.embed = embed
    }

    init(_ core: MarfaCore.Attached) throws {
        self.init(
            upload: try QueuedWrite(core.upload), item: try QueuedWrite(core.item), edge: try QueuedWrite(core.edge),
            embed: core.embed)
    }
}

/// An attached file, and the write that put its embed in the item's body.
public struct Embedded: Sendable, Hashable {
    public var attached: Attached
    public var body: QueuedWrite
    /// What was added to the body.
    public var embed: String

    public init(attached: Attached, body: QueuedWrite, embed: String) {
        self.attached = attached
        self.body = body
        self.embed = embed
    }
}

/// A file was attached, and the edit that embeds it in the body failed.
///
/// The attach's writes are queued. Read the file's item from `attached`, then
/// fix the cause and write the embed with `Items.embedText(of:in:)` and an edit.
public struct EmbedFailure: Error {
    public var attached: Attached
    /// Why the body step failed: `invalid` where the file's title cannot name it alone in an embed.
    public var cause: any Error

    public init(attached: Attached, cause: any Error) {
        self.attached = attached
        self.cause = cause
    }
}

/// What a link or an embed in an item's body names.
public enum BodyTarget: Sendable, Hashable {
    /// The item it names; for an embed, the file item that holds the bytes.
    case item(id: String)
    /// Not looked up on the server yet. A drain, a catch-up or a hydration tries it again.
    case pending
    /// Names no item.
    case missing
    /// Names more than one item.
    case ambiguous
    /// The edge's write, or the server's lookup, was refused.
    case refused(reason: String)

    init(_ core: MarfaCore.BodyTarget) {
        switch core {
        case .item(let id): self = .item(id: id)
        case .pending: self = .pending
        case .missing: self = .missing
        case .ambiguous: self = .ambiguous
        case .refused(let reason): self = .refused(reason: reason)
        }
    }
}

/// A link or an embed as the body carries it, and what it names.
public struct BodyName: Sendable, Hashable {
    /// As typed: `[[Note|shown]]`, `![[photo.png]]`.
    public var text: String
    /// What it is read as: the name before any `|` or `#`, or the embed's path or name.
    public var name: String
    public var target: BodyTarget

    public init(text: String, name: String, target: BodyTarget) {
        self.text = text
        self.name = name
        self.target = target
    }

    init(_ core: MarfaCore.BodyName) {
        self.init(text: core.text, name: core.name, target: BodyTarget(core.target))
    }
}

/// The links in an item's body, and its embeds of files, each in body order.
public struct BodyLinks: Sendable, Hashable {
    public var links: [BodyName]
    public var embeds: [BodyName]

    public init(links: [BodyName] = [], embeds: [BodyName] = []) {
        self.links = links
        self.embeds = embeds
    }

    init(_ core: MarfaCore.BodyLinks) {
        self.init(links: core.links.map(BodyName.init), embeds: core.embeds.map(BodyName.init))
    }
}

public struct Thumbnail: Sendable, Hashable {
    public var mimeType: String
    public var bytes: Data

    public init(mimeType: String, bytes: Data) {
        self.mimeType = mimeType
        self.bytes = bytes
    }

    init(_ core: MarfaCore.Thumbnail) {
        self.init(mimeType: core.mimeType, bytes: core.bytes)
    }
}
