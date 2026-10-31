import Foundation
import Testing

@testable import Marfa

@Suite struct ItemDates {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private var tokyo: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    @Test func aDayHasNoTimeAndStartsOnTheCalendarsClock() throws {
        let utcDay = try #require(ItemDate.parse("2026-10-27", calendar: utc))
        #expect(!utcDay.hasTime)
        #expect(utcDay.date == Date(timeIntervalSince1970: 1_793_059_200))
        let tokyoDay = try #require(ItemDate.parse("2026-10-27", calendar: tokyo))
        #expect(tokyoDay.date == utcDay.date.addingTimeInterval(-9 * 3600), "the same day starts earlier in Tokyo")
    }

    @Test func anInstantHasATimeAndIgnoresTheCalendar() throws {
        let one = try #require(ItemDate.parse("2026-10-27T14:00:00Z", calendar: utc))
        let other = try #require(ItemDate.parse("2026-10-27T23:00:00+09:00", calendar: tokyo))
        #expect(one.hasTime)
        #expect(one.date == other.date)
        #expect(try #require(ItemDate.parse("2026-10-27T14:00Z")).date == one.date)
        #expect(try #require(ItemDate.parse("2026-10-27T14:00:00.250Z")).date == one.date.addingTimeInterval(0.25))
    }

    @Test(arguments: [
        "", "2026-10", "2026-02-30", "2026-13-01", "2026-10-27T14:00:00", "2026-10-27T24:00:00Z",
        "2026-10-27T14:60:00Z", "2026-10-27T14:00:00+24:00", "2026-10-27 14:00:00Z", "2026-10-27T14Z", "20261027",
        "2026-10-27T14:00:00.Z", "2025-02-29",
    ])
    func whatTheContractRefusesIsNotADate(text: String) {
        #expect(ItemDate.parse(text) == nil)
    }

    @Test func aLeapDayExistsInALeapYear() {
        #expect(ItemDate.parse("2028-02-29") != nil)
        #expect(ItemDate.parse("2000-02-29") != nil)
        #expect(ItemDate.parse("1900-02-29") == nil)
    }

    @Test func aDayAndAnInstantAreWrittenInTheirOwnForms() throws {
        let instant = Date(timeIntervalSince1970: 1_793_109_600.123)
        #expect(ItemDate.instant(instant) == "2026-10-27T14:00:00.123Z")
        #expect(ItemDate.day(instant, calendar: utc) == "2026-10-27")
        #expect(ItemDate.day(instant, calendar: tokyo) == "2026-10-27")
        #expect(ItemDate.day(instant.addingTimeInterval(10 * 3600), calendar: tokyo) == "2026-10-28")
        let back = try #require(ItemDate.parse(ItemDate.instant(instant))?.date)
        #expect(abs(back.timeIntervalSince(instant)) < 0.0005, "round trip to the millisecond")
    }

    /// Days on which the clocks go forward at midnight, so the day starts at 01:00, with that start in UTC.
    @Test(arguments: [
        ("America/Santiago", "2026-09-06", "2026-09-06T04:00:00.000Z"),
        ("America/Havana", "2026-03-08", "2026-03-08T05:00:00.000Z"),
        ("America/Asuncion", "2024-10-06", "2024-10-06T04:00:00.000Z"),
    ])
    func aDayStartsWhenItsFirstHourDoesWhereTheClocksSkipMidnight(zone: String, day: String, start: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let parsed = try #require(ItemDate.parse(day, calendar: calendar))
        #expect(ItemDate.instant(parsed.date) == start)
        #expect(ItemDate.day(parsed.date, calendar: calendar) == day, "the day reads back as itself")
    }

    @Test(arguments: [Calendar.Identifier.buddhist, .japanese, .hebrew, .islamicUmmAlQura])
    func aDayIsWrittenOnTheGregorianCalendarWhateverThePersonUses(identifier: Calendar.Identifier) {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let instant = Date(timeIntervalSince1970: 1_793_109_600)
        #expect(ItemDate.day(instant, calendar: calendar) == "2026-10-27")
        #expect(ItemDate.day(instant.addingTimeInterval(10 * 3600), calendar: calendar) == "2026-10-28")
    }

    @Test func datesBefore1582AreWrittenOnTheProlepticGregorianCalendarTheyAreReadOn() throws {
        for text in ["1500-01-01T00:00:00.000Z", "0001-03-01T12:34:56.789Z", "1582-10-04T23:59:59.999Z"] {
            let parsed = try #require(ItemDate.parse(text))
            #expect(ItemDate.instant(parsed.date) == text)
        }
        let day = try #require(ItemDate.parse("1500-01-01", calendar: utc))
        #expect(ItemDate.day(day.date, calendar: utc) == "1500-01-01")
        #expect(ItemDate.day(day.date.addingTimeInterval(-1), calendar: utc) == "1499-12-31")
    }

    private func item(
        properties: JSONObject = [:], created: String = "2026-10-27T14:00:00.000Z", trashed: String? = nil
    ) -> Item {
        Item(
            id: "i", type: "note", properties: properties, state: .active, tier: nil, version: 1, schemaVersion: 1,
            source: "app", sourceId: nil, occurredAt: "2026-10-26T09:30:00.000Z", createdAt: created,
            updatedAt: "2026-10-28T00:00:00.500Z", tags: [], trashedAt: trashed)
    }

    @Test func anItemsOwnTimesAreDates() throws {
        let item = item(trashed: "2026-10-29T10:00:00.000Z")
        #expect(item.createdDate == Date(timeIntervalSince1970: 1_793_109_600))
        #expect(item.occurredDate == Date(timeIntervalSince1970: 1_793_007_000))
        #expect(item.updatedDate == Date(timeIntervalSince1970: 1_793_145_600.5))
        #expect(item.trashedDate == Date(timeIntervalSince1970: 1_793_268_000))
        #expect(self.item().trashedDate == nil)
        #expect(self.item(created: "not a time").createdDate == nil)
    }

    @Test func aPropertyReadsAsADayOrAnInstant() throws {
        let item = item(properties: [
            "due": .string("2026-11-02"), "starts": .string("2026-11-02T08:00:00Z"), "n": .integer(3),
            "bad": .string("soon"),
        ])
        let due = try #require(item.date(forProperty: "due", calendar: utc))
        #expect(!due.hasTime)
        #expect(try #require(item.date(forProperty: "starts", calendar: utc)).hasTime)
        #expect(item.date(forProperty: "n") == nil, "a number is not a date")
        #expect(item.date(forProperty: "bad") == nil)
        #expect(item.date(forProperty: "absent") == nil)
    }

    @Test func filtersTakeAndGiveDates() throws {
        let moment = Date(timeIntervalSince1970: 1_793_109_600.5)
        var list = ListFilters()
        list.occurredAfterDate = moment
        list.updatedBeforeDate = moment
        #expect(list.occurredAfter == "2026-10-27T14:00:00.500Z")
        #expect(list.updatedBefore == "2026-10-27T14:00:00.500Z")
        #expect(list.occurredAfterDate == moment)
        list.occurredAfterDate = nil
        #expect(list.occurredAfter == nil)

        var search = SearchFilters()
        search.occurredBeforeDate = moment
        #expect(search.occurredBefore == "2026-10-27T14:00:00.500Z")
        #expect(search.occurredBeforeDate == moment)

        list.updatedAfter = "2026-10-27"
        #expect(
            list.updatedAfterDate == Date(timeIntervalSince1970: 1_793_059_200),
            "a day bound is the start of the day in UTC")
    }
}
