import Foundation
import MarfaCore

/// A `system.folder`: the query and defaults that folders on disk follow.
public struct Folder: Sendable, Hashable, Identifiable {
    public let id: String
    public let version: Int64
    /// `.revoked` is final: the folder changes no more.
    public let state: ItemState
    public let settings: FolderSettings

    init(_ core: MarfaCore.FolderRow) {
        id = core.id
        version = core.version
        state = core.state
        settings = FolderSettings(core.settings)
    }
}

/// What a folder holds, and what a new file in a folder on disk takes.
public struct FolderSettings: Sendable, Hashable {
    /// Required to create a folder.
    public var title: String?
    public var query: FolderQuery
    public var defaults: FolderDefaults
    /// Gitignore patterns for the paths a folder on disk takes; empty takes every path.
    public var include: [String]
    /// Gitignore patterns for the paths a folder on disk leaves alone; they win over `include`.
    public var ignore: [String]
    /// Where an item of a type made elsewhere first appears, from type to directory.
    public var firstPlacement: [String: String]
    public var removalThreshold: RemovalThreshold

    public init(
        title: String? = nil, query: FolderQuery = FolderQuery(), defaults: FolderDefaults = FolderDefaults(),
        include: [String] = [], ignore: [String] = [], firstPlacement: [String: String] = [:],
        removalThreshold: RemovalThreshold = RemovalThreshold()
    ) {
        self.title = title
        self.query = query
        self.defaults = defaults
        self.include = include
        self.ignore = ignore
        self.firstPlacement = firstPlacement
        self.removalThreshold = removalThreshold
    }

    init(_ core: MarfaCore.FolderSettings) {
        self.init(
            title: core.title, query: FolderQuery(core.query), defaults: FolderDefaults(core.defaults),
            include: core.include, ignore: core.ignore, firstPlacement: core.firstPlacement,
            removalThreshold: RemovalThreshold(core.removalThreshold))
    }

    var core: MarfaCore.FolderSettings {
        MarfaCore.FolderSettings(
            title: title, query: query.core, defaults: defaults.core, include: include, ignore: ignore,
            firstPlacement: firstPlacement, removalThreshold: removalThreshold.core)
    }
}

/// The query that decides which items a folder holds.
public struct FolderQuery: Sendable, Hashable {
    /// Each with its subtypes; empty holds every type but `system.*`.
    public var types: [String]
    /// `nil` holds the library tier. `.all` holds both tiers, and a new file takes ``FolderDefaults/tier``, or
    /// `library` where that is `nil`.
    public var tier: SliceTier?
    /// `nil` holds active and archived items.
    public var states: [ItemState]?
    /// An expression in the server's listing grammar, which takes the `status_group` term as ``ListFilters`` says:
    /// `status_group neq "completed" AND status_group neq "canceled"` holds the open items.
    public var filter: String?
    /// An item id: that item and everything it reaches along `parent-of`.
    public var beneath: String?

    public init(
        types: [String] = [], tier: SliceTier? = nil, states: [ItemState]? = nil, filter: String? = nil,
        beneath: String? = nil
    ) {
        self.types = types
        self.tier = tier
        self.states = states
        self.filter = filter
        self.beneath = beneath
    }

    init(_ core: MarfaCore.FolderQuery) {
        self.init(
            types: core.types, tier: core.tier.map(SliceTier.init), states: core.states,
            filter: core.filter, beneath: core.beneath)
    }

    var core: MarfaCore.FolderQuery {
        MarfaCore.FolderQuery(
            types: types, tier: tier?.core, states: states, filter: filter, beneath: beneath)
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

    init(_ core: MarfaCore.FolderDefaults) {
        self.init(
            type: core.type, tier: core.tier, properties: core.properties,
            tags: core.tags, edges: core.edges)
    }

    var core: MarfaCore.FolderDefaults {
        MarfaCore.FolderDefaults(type: type, tier: tier, properties: properties, tags: tags, edges: edges)
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
    public var query: FolderQuery?
    public var defaults: FolderDefaults?
    public var include: [String]?
    public var ignore: [String]?
    public var firstPlacement: [String: String]?
    public var removalThreshold: RemovalThreshold?

    public init(
        title: String? = nil, query: FolderQuery? = nil, defaults: FolderDefaults? = nil, include: [String]? = nil,
        ignore: [String]? = nil, firstPlacement: [String: String]? = nil, removalThreshold: RemovalThreshold? = nil
    ) {
        self.title = title
        self.query = query
        self.defaults = defaults
        self.include = include
        self.ignore = ignore
        self.firstPlacement = firstPlacement
        self.removalThreshold = removalThreshold
    }

    var core: MarfaCore.FolderSettingsChange {
        MarfaCore.FolderSettingsChange(
            title: title, query: query?.core, defaults: defaults?.core, include: include, ignore: ignore,
            firstPlacement: firstPlacement, removalThreshold: removalThreshold?.core)
    }
}

extension Items {
    /// `nil` where the copy does not hold the folder.
    ///
    /// Throws `MarfaError.invalid` for a held item that is not a `system.folder`, or one whose settings name a
    /// condition no folder follows.
    public func folder(_ id: String) async throws -> Folder? {
        try await holder.run { core in try core.folder(id: id).map(Folder.init) }
    }
}

extension WorkingCopy {
    /// Creates a folder through the server's folder door, at once.
    ///
    /// Folder writes are never queued, because only the folder door writes a `system.folder`: with no server, or
    /// none reachable, this throws and nothing waits to be sent. Settings the core refuses are thrown before
    /// anything is sent: `MarfaError.invalid` for settings no folder follows, and `MarfaError.validation` for a
    /// filter that does not parse or a default tag or property name the server refuses. The copy holds the new
    /// folder at once where its slice or a pin takes it; where it cannot read the row back, the row arrives at the
    /// next catch-up.
    ///
    /// A `network` failure after the request went out may follow a folder the server made. Retry with the same
    /// `idempotencyKey`, which answers the first folder, rather than creating a second.
    public func createFolder(_ settings: FolderSettings, idempotencyKey: String? = nil) async throws -> Folder {
        let folder = try await holder.run { core in
            Folder(try core.createFolder(settings: settings.core, idempotencyKey: idempotencyKey))
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
            Folder(
                try core.changeFolder(
                    id: id, change: change.core, version: baseVersion, idempotencyKey: idempotencyKey))
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
            Folder(try core.revokeFolder(id: id, idempotencyKey: idempotencyKey))
        }
        feed.announce(Change(origin: .refreshed(.folderWritten), itemId: id, edgeId: nil))
        return folder
    }
}
