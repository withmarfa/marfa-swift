import Foundation
import Testing

@testable import Marfa

@Suite struct EventDatesReading {
    /// Zones on either side of the date line and the one between them, which a device may keep.
    static let deviceZones = ["Europe/London", "Pacific/Kiritimati", "Pacific/Pago_Pago"]

    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    private func event(_ properties: JSONObject) -> Item {
        Item(
            id: "e", type: "event", properties: properties, state: .active, tier: nil, version: 1, schemaVersion: 1,
            source: "app", sourceId: nil, occurredAt: "2026-03-01T00:00:00.000Z", createdAt: "2026-03-01T00:00:00.000Z",
            updatedAt: "2026-03-01T00:00:00.000Z", tags: [], trashedAt: nil)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> ItemDate.Day {
        ItemDate.Day(year: year, month: month, day: day)
    }

    @Test(arguments: deviceZones)
    func aBareDateIsItsDayWhateverTheDevicesZone(device: String) throws {
        let calendar = try calendar(device)
        let dates = try #require(event(["starts_at": .string("2026-03-12")]).eventDates(calendar: calendar))
        #expect(dates.isAllDay)
        #expect(dates.start.day == day(2026, 3, 12))
        #expect(dates.end.day == day(2026, 3, 13), "a day with no end is one day long")
        #expect(dates.lastDay == day(2026, 3, 12))
        #expect(!dates.start.hasTime)
        #expect(dates.start.timeZone == nil)
        #expect(ItemDate.day(dates.start.date, calendar: calendar) == "2026-03-12", "its moment is that day's start")
        #expect(ItemDate.day(dates.start.date.addingTimeInterval(-1), calendar: calendar) == "2026-03-11")
    }

    @Test func aBareDateEndNamesTheDayTheEventEndsAtMidnightOf() throws {
        let dates = try #require(
            event(["starts_at": .string("2026-03-12"), "ends_at": .string("2026-03-15")]).eventDates())
        #expect(dates.start.day == day(2026, 3, 12))
        #expect(dates.end.day == day(2026, 3, 15))
        #expect(dates.lastDay == day(2026, 3, 14))
    }

    @Test func aTimedEventKeepsItsInstantsAndShowsThemInItsZones() throws {
        let dates = try #require(
            event([
                "starts_at": .string("2026-03-11T15:00:00.250Z"), "ends_at": .string("2026-03-11T22:30:00Z"),
                "timezone": .string("Europe/London"), "end_timezone": .string("Asia/Tokyo"),
            ]).eventDates(calendar: calendar("Pacific/Kiritimati")))
        #expect(!dates.isAllDay)
        #expect(dates.start.hasTime)
        #expect(dates.start.day == nil)
        #expect(dates.start.date == Date(timeIntervalSince1970: 1_773_241_200.25))
        #expect(dates.start.timeZone?.identifier == "Europe/London")
        #expect(dates.end.date == Date(timeIntervalSince1970: 1_773_268_200))
        #expect(dates.end.timeZone?.identifier == "Asia/Tokyo")
        #expect(dates.lastDay == nil)
    }

    @Test func aTimedEndIsShownInTheStartsZoneWhenItNamesNone() throws {
        let dates = try #require(
            event([
                "starts_at": .string("2026-03-11T15:00:00Z"), "ends_at": .string("2026-03-12T01:00:00+09:00"),
                "timezone": .string("Asia/Tokyo"),
            ]).eventDates())
        #expect(dates.start.timeZone?.identifier == "Asia/Tokyo")
        #expect(dates.end.timeZone?.identifier == "Asia/Tokyo")
        #expect(dates.end.date == Date(timeIntervalSince1970: 1_773_244_800), "the end's own offset is the instant")
    }

    @Test func aTimedEventWithNoZoneHasNoZoneToShow() throws {
        let dates = try #require(
            event(["starts_at": .string("2026-03-11T15:00:00Z"), "all_day": .bool(false)]).eventDates())
        #expect(dates.start.timeZone == nil)
        #expect(dates.end.timeZone == nil)
    }

    @Test func aTimedEndIsTheStartPlusTheDurationOrTheStartItself() throws {
        let start = Date(timeIntervalSince1970: 1_773_241_200)
        let lasting = try #require(
            event(["starts_at": .string("2026-03-11T15:00:00Z"), "duration": .integer(5400)]).eventDates())
        #expect(lasting.end.date == start.addingTimeInterval(5400))
        let fractional = try #require(
            event(["starts_at": .string("2026-03-11T15:00:00Z"), "duration": .number(0.5)]).eventDates())
        #expect(fractional.end.date == start.addingTimeInterval(0.5))
        let none = try #require(event(["starts_at": .string("2026-03-11T15:00:00Z")]).eventDates())
        #expect(none.end.date == start, "an event with no length ends where it starts")
        let outOfRange = try #require(
            event(["starts_at": .string("2026-03-11T15:00:00Z"), "duration": .integer(-5)]).eventDates())
        #expect(outOfRange.end.date == start)
    }

    @Test func aTimedEndBeforeTheStartIsTheStart() throws {
        let dates = try #require(
            event([
                "starts_at": .string("2026-03-11T15:00:00Z"), "ends_at": .string("2026-03-11T14:00:00Z"),
                "duration": .integer(3600), "end_timezone": .string("Asia/Tokyo"),
            ]).eventDates())
        #expect(dates.end.date == dates.start.date, "the end is not read as an earlier moment, and not as the duration")
        #expect(dates.end.timeZone?.identifier == "Asia/Tokyo")
    }

    @Test func aTimedEventReadsADayEndAsMidnightInUTC() throws {
        let dates = try #require(
            event(["starts_at": .string("2026-03-11T15:00:00Z"), "ends_at": .string("2026-03-12")]).eventDates())
        #expect(dates.end.date == Date(timeIntervalSince1970: 1_773_273_600))
        #expect(dates.end.hasTime)
    }

    /// An instant of 15:00 UTC on 11 March is 00:00 on 12 March in Tokyo, whichever zone the device keeps.
    @Test(arguments: deviceZones)
    func anAllDayInstantIsOnTheDayItFallsOnInTheEventsZone(device: String) throws {
        let calendar = try calendar(device)
        let tokyo = try #require(
            event([
                "starts_at": .string("2026-03-11T15:00:00.000Z"), "all_day": .bool(true),
                "timezone": .string("Asia/Tokyo"),
            ]).eventDates(calendar: calendar))
        #expect(tokyo.isAllDay)
        #expect(tokyo.start.day == day(2026, 3, 12))
        #expect(tokyo.end.day == day(2026, 3, 13))
        #expect(tokyo.start.timeZone == nil, "a day has no zone to show")
        #expect(ItemDate.day(tokyo.start.date, calendar: calendar) == "2026-03-12")
    }

    /// With no zone the instant's day is its day in UTC: 11 March, on a device in Kiritimati (12 March there) too.
    @Test(arguments: deviceZones)
    func anAllDayInstantWithNoZoneIsOnItsUTCDay(device: String) throws {
        let calendar = try calendar(device)
        let dates = try #require(
            event(["starts_at": .string("2026-03-11T15:00:00.000Z"), "all_day": .bool(true)])
                .eventDates(calendar: calendar))
        #expect(dates.start.day == day(2026, 3, 11))
        #expect(dates.end.day == day(2026, 3, 12))
        #expect(ItemDate.day(dates.start.date, calendar: calendar) == "2026-03-11")
    }

    /// 23:00 UTC is 13:00 the next day in Kiritimati (UTC+14) and 12:00 the same day in Pago Pago (UTC-11).
    @Test(arguments: [
        ("Pacific/Kiritimati", 12), ("Pacific/Pago_Pago", 11), ("Europe/London", 11), ("UTC", 11),
    ])
    func anAllDayInstantNearTheDateLineFallsOnEachZonesDay(zone: String, expected: Int) throws {
        let dates = try #require(
            event([
                "starts_at": .string("2026-03-11T23:00:00Z"), "all_day": .bool(true), "timezone": .string(zone),
            ]).eventDates(calendar: calendar("Europe/London")))
        #expect(dates.start.day == day(2026, 3, expected))
    }

    @Test func anAllDayEventsEndIsReadInItsZoneToo() throws {
        let dates = try #require(
            event([
                "starts_at": .string("2026-03-11T15:00:00Z"), "ends_at": .string("2026-03-13T14:59:00Z"),
                "all_day": .bool(true), "timezone": .string("Asia/Tokyo"), "end_timezone": .string("Pacific/Pago_Pago"),
            ]).eventDates())
        #expect(dates.start.day == day(2026, 3, 12))
        #expect(dates.end.day == day(2026, 3, 13), "13 March 23:59 in Tokyo, whatever end_timezone says")
        #expect(dates.lastDay == day(2026, 3, 12))
    }

    @Test(arguments: [
        ("ends_at", JSONValue.string("2026-03-10"), 1),
        ("ends_at", .string("2026-03-12"), 1),
        ("ends_at", .string("2026-03-14"), 2),
        ("duration", .integer(86_400), 1),
        ("duration", .integer(86_401), 2),
        ("duration", .number(3 * 86_400), 3),
        ("duration", .integer(3600), 1),
        ("duration", .integer(0), 1),
        ("duration", .integer(-86_400), 1),
        ("duration", .integer(4_000_000_000), 1),
    ])
    func anAllDayEventIsAtLeastOneDayLong(key: String, value: JSONValue, days: Int) throws {
        let dates = try #require(event(["starts_at": .string("2026-03-12"), key: value]).eventDates())
        #expect(dates.end.day == day(2026, 3, 12).adding(days: days))
    }

    @Test func anEndsAtWinsOverADurationForAnAllDayEvent() throws {
        let dates = try #require(
            event(["starts_at": .string("2026-03-12"), "ends_at": .string("2026-03-14"), "duration": .integer(86_400)])
                .eventDates())
        #expect(dates.end.day == day(2026, 3, 14))
    }

    @Test func aBareDateIsAWholeDayEvenWhenAllDayIsFalse() throws {
        let dates = try #require(event(["starts_at": .string("2026-03-12"), "all_day": .bool(false)]).eventDates())
        #expect(dates.isAllDay)
    }

    @Test func aTimeOnADayThatTheDeviceZoneSkipsStillReadsAsThatDay() throws {
        let dates = try #require(
            event(["starts_at": .string("2011-12-30T12:00:00Z"), "all_day": .bool(true), "timezone": .string("UTC")])
                .eventDates(calendar: calendar("Pacific/Apia")))
        #expect(dates.start.day == day(2011, 12, 30), "Samoa had no 30 December that year; the event does")
        #expect(dates.end.day == day(2011, 12, 31))
    }

    /// London's clocks go forward at 01:00 UTC on 29 March 2026 and back at 01:00 UTC on 25 October 2026.
    @Test(arguments: [
        ("2026-03-28T23:59:59Z", 28), ("2026-03-29T00:30:00Z", 29), ("2026-03-29T23:30:00Z", 30),
        ("2026-10-24T23:30:00Z", 25), ("2026-10-25T23:30:00Z", 25), ("2026-10-26T00:00:00Z", 26),
    ])
    func anAllDayInstantFallsOnTheEventsDayEitherSideOfAClockChange(instant: String, expected: Int) throws {
        let month = instant.hasPrefix("2026-03") ? 3 : 10
        let dates = try #require(
            event([
                "starts_at": .string(instant), "all_day": .bool(true), "timezone": .string("Europe/London"),
            ]).eventDates(calendar: calendar("Pacific/Kiritimati")))
        #expect(dates.start.day == day(2026, month, expected))
    }

    @Test func aDayThatAClockChangeShortensIsStillOneDay() throws {
        let dates = try #require(
            event([
                "starts_at": .string("2026-03-28"), "ends_at": .string("2026-03-30"),
                "timezone": .string("Europe/London"),
            ])
            .eventDates(calendar: calendar("Europe/London")))
        #expect(dates.end.day == day(2026, 3, 30))
        #expect(dates.lastDay == day(2026, 3, 29))
        #expect(dates.end.date.timeIntervalSince(dates.start.date) == 47 * 3600, "the clocks lose an hour in the span")
    }

    @Test func anUnknownZoneKeepsATimedInstantAndHidesTheZone() throws {
        let dates = try #require(
            event([
                "starts_at": .string("2026-03-11T15:00:00Z"), "ends_at": .string("2026-03-11T16:00:00Z"),
                "timezone": .string("Mars/Olympus_Mons"), "end_timezone": .string("Europe/London"),
            ]).eventDates())
        #expect(dates.start.date == Date(timeIntervalSince1970: 1_773_241_200))
        #expect(dates.start.timeZone == nil)
        #expect(dates.end.timeZone?.identifier == "Europe/London")
        let endUnknown = try #require(
            event([
                "starts_at": .string("2026-03-11T15:00:00Z"), "timezone": .string("Europe/London"),
                "end_timezone": .string("Mars/Olympus_Mons"),
            ]).eventDates())
        #expect(endUnknown.end.timeZone?.identifier == "Europe/London", "an unknown end zone falls back to the start's")
    }

    @Test(arguments: ["Mars/Olympus_Mons", "", "+09:00"])
    func anUnknownZoneLeavesAnAllDayInstantsDayUnknown(zone: String) {
        let dates = event([
            "starts_at": .string("2026-03-11T15:00:00Z"), "all_day": .bool(true), "timezone": .string(zone),
        ]).eventDates()
        #expect(dates == nil)
    }

    @Test func anUnknownZoneDoesNotHideADayThatNeededNone() throws {
        let dates = try #require(
            event([
                "starts_at": .string("2026-03-12"), "all_day": .bool(true), "timezone": .string("Mars/Olympus_Mons"),
            ])
            .eventDates())
        #expect(dates.start.day == day(2026, 3, 12))
        let withEnd = event([
            "starts_at": .string("2026-03-12"), "ends_at": .string("2026-03-13T10:00:00Z"),
            "timezone": .string("Mars/Olympus_Mons"),
        ]).eventDates()
        #expect(withEnd == nil, "an end that is an instant needs the zone")
    }

    @Test(
        arguments: [
            JSONObject(),
            ["starts_at": .string("soon")],
            ["starts_at": .string("2026-03-11T15:00:00")],
            ["starts_at": .integer(1_773_241_200)],
            ["starts_at": .null, "all_day": .bool(true)],
        ] as [JSONObject])
    func anEventWithNoReadableStartHasNoDates(properties: JSONObject) {
        #expect(event(properties).eventDates() == nil)
    }

    @Test func anUnreadableEndOrAFieldOfTheWrongKindIsLeftOut() throws {
        let dates = try #require(
            event([
                "starts_at": .string("2026-03-11T15:00:00Z"), "ends_at": .string("later"), "all_day": .string("true"),
                "timezone": .integer(9), "end_timezone": .null, "duration": .string("90"),
            ]).eventDates())
        #expect(!dates.isAllDay, "only a boolean true makes a whole-day event")
        #expect(dates.end.date == dates.start.date)
        #expect(dates.start.timeZone == nil)
    }

    @Test func aDayAddsDaysAcrossMonthsYearsAndLeapDays() {
        #expect(day(2026, 3, 31).adding(days: 1) == day(2026, 4, 1))
        #expect(day(2026, 12, 31).adding(days: 1) == day(2027, 1, 1))
        #expect(day(2028, 2, 28).adding(days: 1) == day(2028, 2, 29))
        #expect(day(2026, 3, 1).adding(days: -1) == day(2026, 2, 28))
        #expect(day(2026, 3, 12) < day(2026, 3, 13))
        #expect(day(2026, 3, 12).text == "2026-03-12")
        #expect(day(7, 1, 2).text == "0007-01-02")
    }

    @Test func aParsedDayCarriesItsDay() throws {
        #expect(try #require(ItemDate.parse("2026-03-12")).day == day(2026, 3, 12))
        #expect(try #require(ItemDate.parse("2026-03-12T10:00:00Z")).day == nil)
    }
}
