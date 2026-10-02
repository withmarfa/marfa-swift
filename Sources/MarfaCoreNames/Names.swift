import MarfaCore

// The glue's class shares its module's name, so `MarfaCore.Item` finds the
// class, not the record. This module declares no records of its own, so its
// unqualified names reach the glue's.

public typealias CoreDraft = Draft
public typealias CoreEdge = Edge
public typealias CoreEdgeDraft = EdgeDraft
public typealias CoreEdgeEdit = EdgeEdit
public typealias CoreEdit = Edit
public typealias CoreItem = Item
public typealias CoreListFilters = ListFilters
public typealias CoreSearchFilters = SearchFilters
public typealias CoreSearchHit = SearchHit
public typealias CoreChange = Change
public typealias Core = MarfaCore
public typealias CoreTier = Tier
public typealias CoreItemState = ItemState
public typealias CoreWriteKind = WriteKind
public typealias CoreVerdict = Verdict
public typealias CoreBlockedReason = BlockedReason
public typealias CoreHandle = Handle
public typealias CoreHydration = Hydration
public typealias CoreSortField = SortField
public typealias CoreSortDirection = SortDirection
public typealias CoreSort = Sort
public typealias CoreQueuedWrite = QueuedWrite
public typealias CoreDrainReport = DrainReport
public typealias CoreDrainVerdict = DrainVerdict
public typealias CoreHydrateReport = HydrateReport
public typealias CoreCatchUpReport = CatchUpReport
public typealias CoreStatus = Status
public typealias CoreAttachment = Attachment
public typealias CoreAttached = Attached
public typealias CoreMarfaError = MarfaError
public typealias CoreSubscription = Subscription
public typealias CoreChangeListener = ChangeListener
public typealias CoreThumbnail = Thumbnail
public typealias CoreItemType = ItemType
public typealias CoreEdgeType = EdgeType
public typealias CoreTypeField = TypeField
public typealias CoreEdgeEnd = EdgeEnd
