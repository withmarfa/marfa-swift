#if DEBUG
import Marfa
import MarfaCore

public struct FolderSettingsScript: Sendable {
    public var create: (@Sendable (Marfa.FolderSettings, _ idempotencyKey: String?) throws -> Marfa.Folder)?
    public var change:
        (
            @Sendable (_ id: String, Marfa.FolderSettingsChange, _ baseVersion: Int64, _ idempotencyKey: String?) throws
                -> Marfa.Folder
        )?
    public var read: (@Sendable (_ id: String) throws -> Marfa.Folder?)?

    public init() {}
}

extension InMemoryCore {
    func createFolder(settings: MarfaCore.FolderSettings, idempotencyKey: String?) throws -> FolderRow {
        guard let create = folderSettings.withLock({ $0.create }) else {
            throw FakeCopyError.unsupported(call: "createFolder")
        }
        return try create(Marfa.FolderSettings(settings), idempotencyKey).core
    }

    func changeFolder(id: String, change: MarfaCore.FolderSettingsChange, version: Int64, idempotencyKey: String?)
        throws
        -> FolderRow
    {
        guard let script = folderSettings.withLock({ $0.change }) else {
            throw FakeCopyError.unsupported(call: "changeFolder")
        }
        return try script(id, Marfa.FolderSettingsChange(change), version, idempotencyKey).core
    }

    func folder(id: String) throws -> FolderRow? {
        guard let read = folderSettings.withLock({ $0.read }) else { throw FakeCopyError.unsupported(call: "folder") }
        return try read(id)?.core
    }
}
#endif
