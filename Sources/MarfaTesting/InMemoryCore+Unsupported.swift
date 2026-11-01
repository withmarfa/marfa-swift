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

    func bodyLinksOf(ids: [String]) throws -> [String: BodyLinks] {
        try unsupported("items.links(in:)")
    }

    func changesSince(cursor: String?, most: UInt32) throws -> CopyChanges {
        try unsupported("changes(since:most:)")
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

    func itemDisplays(items: [ItemDisplayInput]) throws -> [ItemDisplay] {
        guard let answer = scripted.withLock({ $0.displays }) else {
            throw FakeCopyError.unsupported(call: "items.displays")
        }
        return items.map(answer)
    }

    func linkCandidates(item: String?, targets: [String]) throws -> [LinkCandidates] {
        guard let answer = scripted.withLock({ $0.linkCandidates }) else {
            throw FakeCopyError.unsupported(call: "links.candidates")
        }
        return targets.map { answer($0, item) }
    }

    func hydrate(types: [String], tier: SliceTier, stop: Stop?) throws -> HydrateReport {
        try unsupported("hydrate")
    }

    func hydrateWith(
        types: [String], tier: SliceTier, edgeTypes: [String], inPlaceOnly: Bool, stop: Stop?
    ) throws -> HydrateReport {
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

    func removeFetchedFiles() throws -> UInt64 {
        try unsupported("blobs.removeFetched")
    }
}
#endif
