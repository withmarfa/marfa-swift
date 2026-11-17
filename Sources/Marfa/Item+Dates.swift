import Foundation

extension Item {
    /// When the item was created, or `nil` where the value is not a time the contract allows.
    public var createdDate: Date? { ItemDate.parse(createdAt)?.date }

    /// When the item was last changed.
    public var updatedDate: Date? { ItemDate.parse(updatedAt)?.date }

    /// When the item's content happened: its own time, or its creation time where it has none of its own.
    public var occurredDate: Date? { ItemDate.parse(occurredAt)?.date }

    /// When the item went to the bin; `nil` outside it, and for a row an archive restored to the bin without the time.
    public var trashedDate: Date? { trashedAt.flatMap { ItemDate.parse($0)?.date } }

    /// The value of the property `name` as a date or an instant, or `nil` where the item holds no such property, it
    /// holds something other than text, or the text is not one of the forms of a `date` or `datetime` value.
    ///
    /// ``ItemDate/hasTime`` tells a `date` field's day from a `datetime` field's instant, so an app shows and edits
    /// each as what it is. A day is read on `calendar`.
    public func date(forProperty name: String, calendar: Calendar = .current) -> ItemDate? {
        guard case .string(let text)? = properties[name] else { return nil }
        return ItemDate.parse(text, calendar: calendar)
    }
}

/// An event's start and end, read as the contract defines them (`occurrences/allday-zone`, `occurrences/allday-utc`,
/// `occurrences/allday-instant`, `occurrences/allday-end`, `occurrences/allday-duration`).
public struct EventDates: Hashable, Sendable {
    /// Where the event starts: a day with no time for a whole-day event, or an instant for a timed one, shown in the
    /// event's `timezone`.
    public let start: ItemDate
    /// Where the event ends, as exclusive as the contract places it: a whole-day event ends at midnight of the day
    /// ``end`` names, which is the day after its last, and a timed event ends at the instant ``end`` names, shown in
    /// `end_timezone`, or `timezone` where it has none. A timed event that states no end, or one before its start, ends
    /// where it starts.
    public let end: ItemDate

    /// Whether the event occupies whole days, so that ``start`` and ``end`` name days.
    public var isAllDay: Bool { start.day != nil }

    /// The last day a whole-day event occupies, or `nil` for a timed event.
    public var lastDay: ItemDate.Day? { end.day?.adding(days: -1) }
}

extension Item {
    /// The event's start and end, or `nil` where the item holds no `starts_at` that is a date or a datetime, or the
    /// event is a whole-day one whose `timezone` names no zone this device knows, so its days are not known.
    ///
    /// An event occupies whole days when its `all_day` is `true` or its `starts_at` is a day with no time. A day belongs
    /// to the event's `timezone`, or to UTC where it has none, so a `starts_at` that is an instant falls on the day it
    /// has in that zone, whatever zone the device keeps. The end is the day of `ends_at` read the same way, else the
    /// days `duration` covers, rounded up, else one day; an end on the start's day or before it is one day long.
    ///
    /// A timed event keeps its instants. Its start is shown in `timezone` and its end in `end_timezone`, or `timezone`
    /// where it has none; a zone name this device does not know leaves the instant as it is and the zone `nil`. The end
    /// is `ends_at`, else the start plus `duration`, else the start. `calendar` places a day that is no instant, as in
    /// ``date(forProperty:calendar:)``; repeating events are not expanded.
    public func eventDates(calendar: Calendar = .current) -> EventDates? {
        guard case .string(let startText)? = properties["starts_at"],
            let start = ItemDate.parse(startText, calendar: calendar)
        else { return nil }
        let endText: String? = if case .string(let text)? = properties["ends_at"] { text } else { nil }
        let zone = ZoneName(properties["timezone"])
        if properties["all_day"] == .bool(true) || !start.hasTime {
            return wholeDays(from: start, endText: endText, zone: zone, calendar: calendar)
        }
        let begin = start.date
        let endDate: Date =
            if let endText, let end = ItemDate.utcInstant(endText) {
                max(end, begin)
            } else if let duration = Self.duration(properties["duration"]) {
                begin.addingTimeInterval(duration)
            } else {
                begin
            }
        let endZone = ZoneName(properties["end_timezone"]).zone ?? zone.zone
        return EventDates(
            start: ItemDate(date: begin, day: nil, timeZone: zone.zone),
            end: ItemDate(date: endDate, day: nil, timeZone: endZone))
    }

    private func wholeDays(from start: ItemDate, endText: String?, zone: ZoneName, calendar: Calendar) -> EventDates? {
        func day(_ value: ItemDate) -> ItemDate.Day? {
            if let day = value.day { return day }
            return zone.dayZone.map { ItemDate.Day(of: value.date, in: $0) }
        }
        guard let first = day(start) else { return nil }
        var length: Int64 = 1
        if let endText, let end = ItemDate.parse(endText, calendar: calendar) {
            guard let last = day(end) else { return nil }
            length = last.epochDay - first.epochDay
        } else if let duration = Self.duration(properties["duration"]) {
            length = Int64((duration / 86_400).rounded(.up))
        }
        length = max(length, 1)
        let after = ItemDate.Day(epochDay: first.epochDay + length)
        guard let startDate = ItemDate.startOfDay(first.year, first.month, first.day, in: calendar.timeZone),
            let endDate = ItemDate.startOfDay(after.year, after.month, after.day, in: calendar.timeZone)
        else { return nil }
        return EventDates(start: ItemDate(date: startDate, day: first), end: ItemDate(date: endDate, day: after))
    }

    /// A `duration` in seconds, or nil where it is absent or outside the contract's range.
    private static func duration(_ value: JSONValue?) -> TimeInterval? {
        let seconds: Double
        switch value {
        case .integer(let number)?: seconds = Double(number)
        case .number(let number)?: seconds = number
        default: return nil
        }
        return (0...3_162_240_000).contains(seconds) ? seconds : nil
    }
}

/// What an event's `timezone` or `end_timezone` property names.
private struct ZoneName {
    /// The zone, or nil where the property is absent, not text, or a name this device does not know.
    let zone: TimeZone?
    /// Whether the property names a zone at all, so that a name this device does not know is told from none.
    let isNamed: Bool

    init(_ value: JSONValue?) {
        guard case .string(let name)? = value else {
            zone = nil
            isNamed = false
            return
        }
        zone = TimeZone(identifier: name)
        isNamed = true
    }

    /// The zone whole days are read in: the named one, UTC where none is named, nil where the name is unknown.
    var dayZone: TimeZone? { isNamed ? zone : .gmt }
}

extension ListFilters {
    /// ``occurredAfter`` as a `Date`; setting it writes the instant the core and the server read.
    ///
    /// A bound given as a day reads as the start of that day in UTC, as the core reads it.
    public var occurredAfterDate: Date? {
        get { occurredAfter.flatMap(ItemDate.utcInstant) }
        set { occurredAfter = newValue.map(ItemDate.instant) }
    }

    /// ``occurredBefore`` as a `Date`.
    public var occurredBeforeDate: Date? {
        get { occurredBefore.flatMap(ItemDate.utcInstant) }
        set { occurredBefore = newValue.map(ItemDate.instant) }
    }

    /// ``updatedAfter`` as a `Date`.
    public var updatedAfterDate: Date? {
        get { updatedAfter.flatMap(ItemDate.utcInstant) }
        set { updatedAfter = newValue.map(ItemDate.instant) }
    }

    /// ``updatedBefore`` as a `Date`.
    public var updatedBeforeDate: Date? {
        get { updatedBefore.flatMap(ItemDate.utcInstant) }
        set { updatedBefore = newValue.map(ItemDate.instant) }
    }
}

extension SearchFilters {
    /// ``occurredAfter`` as a `Date`; setting it writes the instant the core and the server read.
    ///
    /// A bound given as a day reads as the start of that day in UTC, as the core reads it.
    public var occurredAfterDate: Date? {
        get { occurredAfter.flatMap(ItemDate.utcInstant) }
        set { occurredAfter = newValue.map(ItemDate.instant) }
    }

    /// ``occurredBefore`` as a `Date`.
    public var occurredBeforeDate: Date? {
        get { occurredBefore.flatMap(ItemDate.utcInstant) }
        set { occurredBefore = newValue.map(ItemDate.instant) }
    }
}

extension ItemDate {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// The instant a filter bound names, where a day is the start of that day in UTC.
    static func utcInstant(_ text: String) -> Date? {
        parse(text, calendar: utc)?.date
    }

    /// The instant a value with a time names, or nil for a day alone.
    static func utcTime(_ text: String) -> Date? {
        parse(text, calendar: utc).flatMap { $0.hasTime ? $0.date : nil }
    }
}
