import Foundation
import MarfaCore

/// A `system.folder`: the saved search and defaults that folders on disk and
/// an app's sidebar follow.
public struct Folder: Sendable, Hashable, Identifiable {
    public let id: String
    public let version: Int64
    /// `.revoked` is final: the folder changes no more.
    public let state: ItemState
    public let settings: FolderSettings

    init(_ core: MarfaCore.FolderRow) throws {
        id = core.id
        version = core.version
        state = ItemState(core.state)
        settings = try FolderSettings(core.settings)
    }
}

/// What a folder holds, and what a new file in a folder on disk takes.
public struct FolderSettings: Sendable, Hashable {
    /// Required to create a folder.
    public var title: String?
    public var search: FolderSearch
    public var defaults: FolderDefaults
    /// Gitignore patterns for the paths a folder on disk takes; empty takes every path.
    public var include: [String]
    /// Gitignore patterns for the paths a folder on disk leaves alone; they win over `include`.
    public var ignore: [String]
    /// Where an item of a type made elsewhere first appears, from type to directory.
    public var firstPlacement: [String: String]
    public var removalThreshold: RemovalThreshold

    public init(
        title: String? = nil, search: FolderSearch = FolderSearch(), defaults: FolderDefaults = FolderDefaults(),
        include: [String] = [], ignore: [String] = [], firstPlacement: [String: String] = [:],
        removalThreshold: RemovalThreshold = RemovalThreshold()
    ) {
        self.title = title
        self.search = search
        self.defaults = defaults
        self.include = include
        self.ignore = ignore
        self.firstPlacement = firstPlacement
        self.removalThreshold = removalThreshold
    }

    init(_ core: MarfaCore.FolderSettings) throws {
        self.init(
            title: core.title, search: FolderSearch(core.search), defaults: try FolderDefaults(core.defaults),
            include: core.include, ignore: core.ignore, firstPlacement: core.firstPlacement,
            removalThreshold: RemovalThreshold(core.removalThreshold))
    }

    func core() throws -> MarfaCore.FolderSettings {
        MarfaCore.FolderSettings(
            title: title, search: search.core, defaults: try defaults.core(), include: include, ignore: ignore,
            firstPlacement: firstPlacement, removalThreshold: removalThreshold.core)
    }
}

/// The search that decides which items a folder holds.
public struct FolderSearch: Sendable, Hashable {
    /// Each with its subtypes; empty holds every type but `system.*`.
    public var types: [String]
    /// `nil` holds the library tier.
    public var tier: Tier?
    /// `nil` holds active and archived items.
    public var states: [ItemState]?
    /// An expression in the server's listing grammar.
    public var filter: String?
    /// An item id: that item and everything it reaches along `parent-of`.
    public var beneath: String?

    public init(
        types: [String] = [], tier: Tier? = nil, states: [ItemState]? = nil, filter: String? = nil,
        beneath: String? = nil
    ) {
        self.types = types
        self.tier = tier
        self.states = states
        self.filter = filter
        self.beneath = beneath
    }

    init(_ core: MarfaCore.FolderSearch) {
        self.init(
            types: core.types, tier: core.tier.map(Tier.init), states: core.states?.map(ItemState.init),
            filter: core.filter, beneath: core.beneath)
    }

    var core: MarfaCore.FolderSearch {
        MarfaCore.FolderSearch(
            types: types, tier: tier?.core, states: states?.map(\.core), filter: filter, beneath: beneath)
    }
}

/// What a new file in a folder on disk takes where it leaves a blank.
public struct FolderDefaults: Sendable, Hashable {
    public var type: String?
    public var tier: Tier?
    public var properties: JSONObject
    public var tags: [String]
    /// From edge type to the ids of the items each new file is linked to.
    public var edges: [String: [String]]

    public init(
        type: String? = nil, tier: Tier? = nil, properties: JSONObject = JSONObject(), tags: [String] = [],
        edges: [String: [String]] = [:]
    ) {
        self.type = type
        self.tier = tier
        self.properties = properties
        self.tags = tags
        self.edges = edges
    }

    init(_ core: MarfaCore.FolderDefaults) throws {
        self.init(
            type: core.type, tier: core.tier.map(Tier.init), properties: try JSONObject(json: core.propertiesJson),
            tags: core.tags, edges: core.edges)
    }

    func core() throws -> MarfaCore.FolderDefaults {
        MarfaCore.FolderDefaults(
            type: type, tier: tier?.core, propertiesJson: try properties.json(), tags: tags, edges: edges)
    }
}

/// How large a removal from a folder on disk must be to wait for confirmation.
public struct RemovalThreshold: Sendable, Hashable {
    /// `nil` is 10.
    public var files: UInt64?
    /// `nil` is 0.25.
    public var fraction: Double?

    public init(files: UInt64? = nil, fraction: Double? = nil) {
        self.files = files
        self.fraction = fraction
    }

    init(_ core: MarfaCore.RemovalThreshold) {
        self.init(files: core.files, fraction: core.fraction)
    }

    var core: MarfaCore.RemovalThreshold { MarfaCore.RemovalThreshold(files: files, fraction: fraction) }
}

/// The settings to replace, each whole; a `nil` one is left as it is.
public struct FolderSettingsChange: Sendable, Hashable {
    public var title: String?
    public var search: FolderSearch?
    public var defaults: FolderDefaults?
    public var include: [String]?
    public var ignore: [String]?
    public var firstPlacement: [String: String]?
    public var removalThreshold: RemovalThreshold?

    public init(
        title: String? = nil, search: FolderSearch? = nil, defaults: FolderDefaults? = nil, include: [String]? = nil,
        ignore: [String]? = nil, firstPlacement: [String: String]? = nil, removalThreshold: RemovalThreshold? = nil
    ) {
        self.title = title
        self.search = search
        self.defaults = defaults
        self.include = include
        self.ignore = ignore
        self.firstPlacement = firstPlacement
        self.removalThreshold = removalThreshold
    }

    func core() throws -> MarfaCore.FolderSettingsChange {
        MarfaCore.FolderSettingsChange(
            title: title, search: search?.core, defaults: try defaults?.core(), include: include, ignore: ignore,
            firstPlacement: firstPlacement, removalThreshold: removalThreshold?.core)
    }
}

extension Items {
    /// What the folder's search holds, as a folder on disk holds it, read from the copy alone.
    ///
    /// Throws `MarfaError.invalid` where the copy cannot answer the search whole, never answering part of it: a type
    /// or the tier the search holds that the slice does not, `beneath` without `parent-of` held whole, a revoked
    /// folder, and settings naming a condition no folder follows, such as a `backref`. Throws `MarfaError.notFound`
    /// with the code `not_held` for a folder the copy does not hold; hydrate with `system.folder` in the slice, or
    /// pin it.
    public func list(
        inFolder id: String, sort: Sort = Sort(field: .createdAt, direction: .descending), limit: UInt32? = nil,
        offset: UInt32? = nil
    ) async throws -> [Item] {
        try await holder.run { core in
            try core.listInFolder(id: id, sort: sort.core, limit: limit, offset: offset).map(Item.init)
        }
    }

    /// `nil` where the copy does not hold the folder.
    public func folder(_ id: String) async throws -> Folder? {
        try await holder.run { core in try core.folder(id: id).map(Folder.init) }
    }
}

extension WorkingCopy {
    /// A full-text search narrowed to what the folder holds; it throws as `items.list(inFolder:)` throws.
    public func search(_ query: String, inFolder id: String, limit: Int = 20) async throws -> [SearchHit] {
        try await holder.run { core in
            try core.searchInFolder(query: query, id: id, limit: UInt32(clamping: limit)).map(SearchHit.init)
        }
    }

    /// Creates a folder through the server's folder door, at once.
    ///
    /// Folder writes are never queued, because only the folder door writes a `system.folder`: with no server, or
    /// none reachable, this throws and nothing waits to be sent. Settings no folder follows throw
    /// `MarfaError.invalid` before anything is sent. The copy holds the new folder at once where its slice or a pin
    /// takes it. A repeat under the same `idempotencyKey` answers the first folder.
    public func createFolder(_ settings: FolderSettings, idempotencyKey: String? = nil) async throws -> Folder {
        let folder = try await holder.run { core in
            try Folder(core.createFolder(settings: try settings.core(), idempotencyKey: idempotencyKey))
        }
        feed.announce(Change(origin: .refreshed(.folderWritten), itemId: folder.id, edgeId: nil))
        return folder
    }

    /// Replaces each setting `change` names, based on `baseVersion`, sent as `createFolder(_:)` is.
    ///
    /// A setting changed since `baseVersion` throws `MarfaError.server` with status 409 and the code
    /// `version_conflict`; a revoked folder throws `MarfaError.validation` with the code `invalid_transition`.
    public func changeFolder(
        _ id: String, _ change: FolderSettingsChange, baseVersion: Int64, idempotencyKey: String? = nil
    ) async throws -> Folder {
        let folder = try await holder.run { core in
            try Folder(
                core.changeFolder(
                    id: id, change: try change.core(), version: baseVersion, idempotencyKey: idempotencyKey))
        }
        feed.announce(Change(origin: .refreshed(.folderWritten), itemId: id, edgeId: nil))
        return folder
    }

    /// Revokes a folder, sent as `createFolder(_:)` is.
    ///
    /// A revoked folder changes no more; revoking it again throws `MarfaError.validation` with the code
    /// `invalid_transition`.
    public func revokeFolder(_ id: String, idempotencyKey: String? = nil) async throws -> Folder {
        let folder = try await holder.run { core in
            try Folder(core.revokeFolder(id: id, idempotencyKey: idempotencyKey))
        }
        feed.announce(Change(origin: .refreshed(.folderWritten), itemId: id, edgeId: nil))
        return folder
    }
}
