#if DEBUG
import Foundation
import MarfaCore

/// The calls the fake does not serve. Each throws, so a test that reaches one
/// fails plainly instead of getting an empty answer.
extension InMemoryCore {
    private func unsupported<T>(_ call: String) throws -> T {
        throw FakeCopyError.unsupported(call: call)
    }

    func addFile(path: String, attachment: Attachment, tags: [String]) throws -> Added {
        try unsupported("addFile")
    }

    func attach(id: String, path: String, attachment: Attachment) throws -> Attached {
        try unsupported("items.attach")
    }

    func bin(type: String?, cursor: String?, limit: UInt32) throws -> BinPage {
        try unsupported("items.bin")
    }

    func blob(hash: String) throws -> BlobPath {
        try unsupported("blobs.withFile")
    }

    func blobHeld(hash: String) throws -> Bool {
        try unsupported("blobs.isHeld")
    }

    func bodyLinks(id: String) throws -> BodyLinks {
        try unsupported("items.links")
    }

    func catchUp(stop: Stop?) throws -> CatchUpReport {
        try unsupported("catchUp")
    }

    func conflictedCopiesOf(id: String) throws -> [Item] {
        try unsupported("items.conflictedCopies")
    }

    func dataVersion() throws -> Int64 {
        try unsupported("dataVersion")
    }

    func embedText(id: String, file: String) throws -> String {
        try unsupported("items.embedText")
    }

    func follow(toldUnreachable: Bool, listener: ChangeListener) -> Subscription {
        preconditionFailure("the package never follows a core directly; MarfaTesting has no follow")
    }

    func hydrate(types: [String], tier: SliceTier, stop: Stop?) throws -> HydrateReport {
        try unsupported("hydrate")
    }

    func hydrateWith(types: [String], tier: SliceTier, edgeTypes: [String], stop: Stop?) throws -> HydrateReport {
        try unsupported("hydrate")
    }

    func originalOfConflictedCopy(id: String) throws -> String? {
        try unsupported("items.original")
    }

    func pin(id: String) throws -> PinReport {
        try unsupported("pin")
    }

    func purgeItem(id: String, version: Int64?) throws {
        throw FakeCopyError.unsupported(call: "items.purge")
    }

    func putBlob(path: String, mimeType: String?) throws -> QueuedWrite {
        try unsupported("blobs.put")
    }

    func release(id: String) throws -> Bool {
        try unsupported("queue.release")
    }

    func releaseReason(reason: BlockedReason) throws -> UInt64 {
        try unsupported("queue.release(reason:)")
    }

    func search(query: String, filters: SearchFilters, limit: UInt32) throws -> Found {
        try unsupported("search")
    }

    func thumbnail(id: String) throws -> Thumbnail? {
        try unsupported("items.thumbnail")
    }

    func unpin(id: String) throws -> PinReport {
        try unsupported("unpin")
    }

    func watch(toldUnreachable: Bool, listener: ChangeListener) throws -> Subscription {
        try unsupported("watch")
    }

    func changeFolder(id: String, change: FolderSettingsChange, version: Int64, idempotencyKey: String?) throws
        -> FolderRow
    {
        try unsupported("changeFolder")
    }

    func createFolder(settings: FolderSettings, idempotencyKey: String?) throws -> FolderRow {
        try unsupported("createFolder")
    }

    func folder(id: String) throws -> FolderRow? {
        try unsupported("folder")
    }

    func listInFolder(id: String, sort: Sort, limit: UInt32?, offset: UInt32?) throws -> Listing {
        try unsupported("listInFolder")
    }

    func revokeFolder(id: String, idempotencyKey: String?) throws -> FolderRow {
        try unsupported("revokeFolder")
    }

    func searchInFolder(query: String, id: String, limit: UInt32) throws -> Found {
        try unsupported("searchInFolder")
    }

    func fetchKept(stop: Stop?) throws -> KeptFetch {
        try unsupported("blobs.fetchKept")
    }

    func fileCache() throws -> FileCache {
        try unsupported("blobs.cache")
    }

    func setFileBudget(budget: FileBudget) throws -> UInt64 {
        try unsupported("blobs.setBudget")
    }

    func trimFiles() throws -> UInt64 {
        try unsupported("blobs.trim")
    }

    func createView(settings: JsonObject, idempotencyKey: String?) throws -> ViewRow {
        try unsupported("createView")
    }

    func changeView(id: String, changes: JsonObject, version: Int64, idempotencyKey: String?) throws -> ViewRow {
        try unsupported("changeView")
    }

    func deleteView(id: String, idempotencyKey: String?) throws {
        throw FakeCopyError.unsupported(call: "deleteView")
    }

    func listViews() throws -> Views {
        try unsupported("items.views")
    }

    func view(id: String) throws -> ViewRow? {
        try unsupported("items.view")
    }

    func listInView(id: String, layout: String?, limit: UInt32?, offset: UInt32?) throws -> Listing {
        try unsupported("items.list(inView:)")
    }

    func searchInView(query: String, id: String, limit: UInt32) throws -> Found {
        try unsupported("search(inView:)")
    }

    func viewGroups(id: String, layout: String, timeZone: String?) throws -> ViewGroups {
        try unsupported("items.groups(inView:)")
    }
}
#endif
