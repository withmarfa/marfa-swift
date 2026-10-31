import Marfa

public func checkImports() {
    let tier: Tier = .library
    let state: ItemState = .active
    let member = JSONMember(key: "title", value: .string("Note"))
    let properties = JSONObject(members: [member])
    let value: JSONValue = .object(properties)
    precondition(member.key == "title" && value.object == properties)
    let item = Item(
        id: "note", type: "core.note", properties: properties, state: state,
        tier: tier, version: 1, schemaVersion: 1, source: "consumer", sourceId: nil,
        occurredAt: "", createdAt: "", updatedAt: "", tags: [])
    precondition(item.id == "note" && item.state == .active && item.tier == .library)
    let page = BinPage(items: [item], nextCursor: "next")
    precondition(page.items.first?.id == item.id && page.nextCursor == "next")
    let edge = Edge(
        id: "edge", sourceId: item.id, targetId: "other", edgeType: "parent-of",
        properties: [:], version: 1, createdAt: "", updatedAt: "")
    precondition(edge.sourceId == item.id)
    func identity<Row: Identifiable>(_ row: Row) -> Row.ID { row.id }
    precondition(identity(item) == "note" && identity(edge) == "edge")
    let hit = SearchHit(item: item, score: 1, snippet: "Note")
    precondition(hit.item.id == item.id && hit.score == 1)
    let draft = Draft(type: item.type, properties: properties, tier: tier)
    let edit = Edit(properties: properties, baseVersion: item.version)
    precondition(draft.type == item.type && edit.baseVersion == item.version)
    let list = ListFilters(state: state, tier: tier)
    let search = SearchFilters(state: state)
    precondition(list.tier == tier && search.state == state)
    let queued = QueuedWrite(id: "write", kind: .createItem, idempotencyKey: "key", queuedAt: "")
    let report = DrainReport()
    let error = MarfaError.invalid(message: "consumer")
    let slice: SliceTier = .all
    let edgeEdit = EdgeEdit(baseVersion: edge.version, move: .source("third"))
    precondition(queued.id == "write" && report.unsent == 0 && error.code() == "invalid")
    precondition(slice == .all && edgeEdit.move == .source("third"))
    let group = ViewGroup(key: .string("todo"), count: 2)
    let settings = ViewSettings(
        title: "Tasks", query: ViewQuery(types: ["core.task"], tier: .all),
        sort: [ViewSort(by: "title", direction: .ascending)], group: ViewGrouping(by: "properties.status"))
    precondition(group.count == 2 && settings.group?.by == "properties.status")
    let notHeld = NotHeldAttachments(reason: NotHeldReason.rateLimited, attachments: 2, bytes: 9, unstated: 1)
    let kept = KeptAttachments(
        held: 1, heldBytes: 4, partialBytes: 0, notHeld: 2, notHeldBytes: 9, notHeldByReason: [notHeld])
    let cache = FileCache(
        setting: FileBudget.keepAll, budget: nil, held: 0, heldUnreadable: nil, volumeUnreadable: false,
        backupMarkFailure: nil, attachments: kept)
    precondition(Status(fileCache: cache).fileCache.setting == .keepAll)
    precondition(KeptFetch(fetched: 1, fetchedBytes: 4, attachments: kept).attachments?.notHeld == 2)
    let rows = Rows([group], completeness: Completeness.partial)
    precondition(rows.count == 1 && rows.completeness == .partial)
}
