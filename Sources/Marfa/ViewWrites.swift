import Foundation
import MarfaCore

/// The settings to replace, each whole; a `nil` one is left as it is.
public struct ViewSettingsChange: Sendable, Hashable {
    public var title: String?
    public var query: ViewQuery?
    /// In order, and at least one.
    public var layouts: [ViewLayout]?

    public init(title: String? = nil, query: ViewQuery? = nil, layouts: [ViewLayout]? = nil) {
        self.title = title
        self.query = query
        self.layouts = layouts
    }

    var json: JSONObject {
        var object = JSONObject()
        if let title { object["title"] = .string(title) }
        if let query { object["query"] = .object(query.json) }
        if let layouts { object["layouts"] = .array(layouts.map { .object($0.json) }) }
        return object
    }
}

extension ViewSettings {
    var json: JSONObject {
        ViewSettingsChange(title: title, query: query, layouts: layouts).json
    }
}

extension ViewQuery {
    fileprivate var json: JSONObject {
        var object = JSONObject()
        if !types.isEmpty { object["types"] = .array(types.map { .string($0) }) }
        if let tier { object["tier"] = .string(tier.wire) }
        if let states {
            object["state"] = .array(
                states.map { state in
                    switch state {
                    case .active: "active"
                    case .archived: "archived"
                    case .trashed: "trashed"
                    case .revoked: "revoked"
                    }
                })
        }
        if let filter { object["filter"] = .string(filter) }
        if let beneath { object["beneath"] = .string(beneath) }
        return object
    }
}

extension ViewLayout {
    fileprivate var json: JSONObject {
        var object: JSONObject = ["id": .string(id)]
        switch kind {
        case .list: object["kind"] = "list"
        case .table: object["kind"] = "table"
        case .board: object["kind"] = "board"
        case .gallery(let image):
            object["kind"] = "gallery"
            if let image { object["image"] = .string(image) }
        case .calendar(let date, let end):
            object["kind"] = "calendar"
            if let date { object["date"] = .string(date) }
            if let end { object["end"] = .string(end) }
        case .timeline(let start, let end):
            object["kind"] = "timeline"
            object["start"] = .string(start)
            object["end"] = .string(end)
        case .chart(let x, let y):
            object["kind"] = "chart"
            if let x { object["x"] = .string(x) }
            if let y { object["y"] = y.json }
        case .map(let location):
            object["kind"] = "map"
            if let location { object["location"] = .string(location) }
        }
        if let title { object["title"] = .string(title) }
        if !sort.isEmpty { object["sort"] = .array(sort.map { .object($0.json) }) }
        if let group { object["group"] = .object(group.json) }
        if !shown.isEmpty { object["shown"] = .array(shown.map { .string($0) }) }
        return object
    }
}

extension ViewSort {
    fileprivate var json: JSONObject {
        ["by": .string(by), "direction": .string(direction == .ascending ? "asc" : "desc")]
    }
}

extension ViewGrouping {
    fileprivate var json: JSONObject {
        var object: JSONObject = ["by": .string(by)]
        switch bucket {
        case .day: object["bucket"] = "day"
        case .week: object["bucket"] = "week"
        case .month: object["bucket"] = "month"
        case .year: object["bucket"] = "year"
        case nil: break
        }
        if !order.isEmpty { object["order"] = .array(order) }
        if !hidden.isEmpty { object["hidden"] = .array(hidden) }
        return object
    }
}

extension ViewMeasure {
    fileprivate var json: JSONValue {
        switch self {
        case .count: "count"
        case .sum(let property): ["sum": .string(property)]
        }
    }
}

extension WorkingCopy {
    /// Creates a view through the server's view door, at once.
    ///
    /// View writes are never queued: with no server, or none reachable, this throws and nothing waits to be sent.
    /// `MarfaError.noServer` is thrown for a copy with no server, and `MarfaError.network` for one that cannot reach
    /// it. The server's refusals are thrown as they are: `MarfaError.validation` with the code `validation_error` for
    /// a query it does not accept, and `MarfaError.forbidden` with the code `type_not_permitted` for a key that may
    /// not write `system.view`. The copy holds the new view at once where its slice or a pin takes it; where it
    /// cannot read the row back, the row arrives at the next catch-up.
    ///
    /// Throws `MarfaError.invalid` for an answer this build cannot read as a view, which the server has accepted all
    /// the same.
    ///
    /// A `network` failure after the request went out may follow a view the server made. Retry with the same
    /// `idempotencyKey`, which answers the first view, rather than creating a second.
    public func createView(_ settings: ViewSettings, idempotencyKey: String? = nil) async throws -> SavedView {
        let settings = settings.json
        let row = try await holder.run { core in
            try core.createView(settings: settings, idempotencyKey: idempotencyKey)
        }
        feed.announce(Change(origin: .refreshed(.viewWritten), itemId: row.id, edgeId: nil))
        return try SavedView(row)
    }

    /// Replaces each setting `change` names, based on `baseVersion`, sent as ``createView(_:idempotencyKey:)`` is.
    ///
    /// The server merges a change to settings nobody else changed since `baseVersion`. A setting changed since then
    /// throws `MarfaError.server` with status 409 and the code `version_conflict`, and the copy keeps the view it
    /// held. A revoked view throws `MarfaError.validation` with the code `invalid_transition`, and a view the
    /// server does not have throws `MarfaError.notFound` with the code `item_not_found`.
    public func changeView(
        _ id: String, _ change: ViewSettingsChange, baseVersion: Int64, idempotencyKey: String? = nil
    ) async throws -> SavedView {
        let changes = change.json
        let row = try await holder.run { core in
            try core.changeView(id: id, changes: changes, version: baseVersion, idempotencyKey: idempotencyKey)
        }
        feed.announce(Change(origin: .refreshed(.viewWritten), itemId: id, edgeId: nil))
        return try SavedView(row)
    }

    /// Deletes a view for good, sent as ``createView(_:idempotencyKey:)`` is, and removes it from the copy.
    ///
    /// A view the server no longer has throws `MarfaError.notFound` with the code `item_not_found`. Retry a delete
    /// that failed with a `network` error with the same `idempotencyKey`, which answers the delete the server
    /// accepted rather than refusing the view as gone. A revoked view can be deleted.
    public func deleteView(_ id: String, idempotencyKey: String? = nil) async throws {
        try await holder.run { core in try core.deleteView(id: id, idempotencyKey: idempotencyKey) }
        feed.announce(Change(origin: .refreshed(.purged), itemId: id, edgeId: nil))
    }
}
