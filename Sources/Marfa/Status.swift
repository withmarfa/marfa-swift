import Foundation
package import MarfaCore

/// Where an item stands, as every type with a status field puts it: one of four groups that are the same for every
/// type, so an app can tell what is open, active or finished without knowing a type's own words.
///
/// The raw value is the word the API uses, as a filter's `status_group` term takes it.
public enum StatusGroup: String, Sendable, Hashable, CaseIterable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case completed
    case canceled
}

/// One word a type's status field takes, with its group.
public struct StatusWord: Sendable, Hashable {
    /// The word an item holds in the status field, such as `blocked`.
    public let value: String
    public let group: StatusGroup

    /// For an app's previews and tests.
    public init(value: String, group: StatusGroup) {
        self.value = value
        self.group = group
    }

    /// The words a status field's definition lists, in order.
    ///
    /// An entry that is not a word with one of the four groups is left out, as it would be from a server newer than the
    /// SDK.
    static func words(in definition: JSONObject) -> [StatusWord] {
        (definition["status_values"]?.array ?? []).compactMap { entry in
            guard let entry = entry.object, let value = entry["value"]?.string,
                let group = entry["group"]?.string.flatMap(StatusGroup.init(rawValue:))
            else { return nil }
            return StatusWord(value: value, group: group)
        }
    }
}

extension ItemType {
    /// The group of `word` among this type's status words, or `nil` where the type has no status field or does not
    /// declare the word.
    public func statusGroup(of word: String) -> StatusGroup? {
        statusWords.first { $0.value == word }?.group
    }

    /// The group of the word `item` holds in this type's status field.
    ///
    /// It is `nil` for an item of another type, even a subtype, whose own words this type may not hold: read the
    /// item's own type, as ``Catalog/statusGroup(of:)`` does. It is also `nil` where the type has no status field,
    /// the item holds no word in it, or the word is not one the type declares, as can happen where a type stopped
    /// declaring a word its items still hold.
    public func statusGroup(of item: Item) -> StatusGroup? {
        guard item.type == id, let statusField, let word = item.properties[statusField]?.string else { return nil }
        return statusGroup(of: word)
    }
}

extension Catalog {
    /// The group of the word `item` holds in the status field of its own type, as the catalog holds the type.
    ///
    /// It is `nil` where the type has no status field, the item holds no word in it, or the word is not one the type
    /// declares. Like ``itemType(_:)``, it throws `notFound`, with the code `type_not_found`, for an item whose type
    /// the catalog does not hold.
    public func statusGroup(of item: Item) async throws -> StatusGroup? {
        try await holder.run { core in ItemType(try core.itemType(id: item.type)).statusGroup(of: item) }
    }

    /// The group of each item's status word, in the order of `items`.
    ///
    /// Each answer is the one ``statusGroup(of:)`` gives, except that an item whose type the catalog does not hold
    /// has `nil` and does not fail the rest. A type is read once, whatever the number of items it holds.
    public func statusGroups(of items: [Item]) async throws -> [StatusGroup?] {
        try await holder.run { core in
            var types: [String: ItemType?] = [:]
            return try items.map { item in
                if types[item.type] == nil {
                    do {
                        types[item.type] = .some(ItemType(try core.itemType(id: item.type)))
                    } catch MarfaCore.MarfaError.NotFound {
                        types[item.type] = .some(nil)
                    }
                }
                return types[item.type]??.statusGroup(of: item)
            }
        }
    }

    /// The status of `item`, an event: an item of `core.event` or of a type that descends from it.
    ///
    /// A subtype cannot change the values of a field it inherits, so its items hold the same three. It is `nil` for
    /// an item of any other type, and for an event that holds no status or one this SDK does not know, as from a
    /// server newer than the SDK. Like ``itemType(_:)``, it throws `notFound`, with the code `type_not_found`, for an
    /// item whose type the catalog does not hold.
    public func eventStatus(of item: Item) async throws -> EventStatus? {
        try await holder.run { core in
            var current: String? = item.type
            var seen: Set<String> = []
            while let id = current, seen.insert(id).inserted {
                if id == "core.event" {
                    return item.properties["status"]?.string.flatMap(EventStatus.init(rawValue:))
                }
                current = try core.itemType(id: id).parent
            }
            return nil
        }
    }
}

/// The three values of an event's status, which Marfa fixes.
///
/// They are the values of `core.event`'s `status` field, which a subtype keeps. ``Catalog/eventStatus(of:)`` reads an
/// item's.
///
/// An event's status has no groups: it is not a status field.
public enum EventStatus: String, Sendable, Hashable, CaseIterable {
    /// The event might not happen.
    case tentative
    /// The event will happen.
    case confirmed
    /// The event will not happen.
    case canceled
}
