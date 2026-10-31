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
}
