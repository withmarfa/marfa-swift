import Foundation

/// A value of a Marfa `date` or `datetime` field, read and written in the forms the contract allows
/// (`types/datetime-value`): a calendar day, `YYYY-MM-DD`, or a day followed by `T`, a time of `HH:MM`, `HH:MM:SS`
/// or `HH:MM:SS` with a fraction, and `Z` or a `±HH:MM` offset.
///
/// A day names no moment, so it reads as the start of that day on the calendar given, and ``hasTime`` is `false`;
/// an app shows it as a day and writes it back with ``day(_:calendar:)``, never as an instant.
public struct ItemDate: Hashable, Sendable {
    /// The moment the value names.
    ///
    /// A day is its start in the calendar's time zone.
    public let date: Date
    /// Whether the value names a time, rather than a whole day.
    public let hasTime: Bool

    /// Reads a value as Marfa writes it, or nil where it is not one of the contract's forms or names a day or time
    /// the calendar does not have.
    ///
    /// A value with a time and no zone is refused, as the server refuses it.
    public static func parse(_ text: String, calendar: Calendar = .current) -> ItemDate? {
        // Read from the bytes rather than with a pattern, which is far slower than this for a library of items.
        var reader = Reader(text)
        guard let year = reader.digits(4), reader.take("-"), let month = reader.digits(2), reader.take("-"),
            let dayOfMonth = reader.digits(2)
        else { return nil }
        if reader.atEnd {
            return startOfDay(year, month, dayOfMonth, in: calendar.timeZone).map { ItemDate(date: $0, hasTime: false) }
        }
        guard reader.take("T"), let hour = reader.digits(2), reader.take(":"), let minute = reader.digits(2) else {
            return nil
        }
        var seconds = 0
        var fractional = 0.0
        if reader.take(":") {
            guard let second = reader.digits(2) else { return nil }
            seconds = second
            if reader.take(".") {
                guard let fraction = reader.digitRun(), let value = Double("0." + fraction) else { return nil }
                fractional = value
            }
        }
        let offset: Int
        if reader.take("Z") {
            offset = 0
        } else {
            let sign = reader.take("-") ? -1 : reader.take("+") ? 1 : 0
            guard sign != 0, let hours = reader.digits(2), reader.take(":"), let minutes = reader.digits(2),
                hours <= 23, minutes <= 59
            else { return nil }
            offset = sign * (hours * 3600 + minutes * 60)
        }
        guard reader.atEnd, let start = utcMidnight(year, month, dayOfMonth), hour <= 23, minute <= 59, seconds <= 59
        else { return nil }
        let interval = TimeInterval(hour * 3600 + minute * 60 + seconds - offset) + fractional
        return ItemDate(date: start.addingTimeInterval(interval), hasTime: true)
    }

    /// Reads a value's ASCII parts in order.
    private struct Reader {
        private let bytes: String.UTF8View
        private var index: String.Index

        init(_ text: String) {
            bytes = text.utf8
            index = bytes.startIndex
        }

        var atEnd: Bool { index == bytes.endIndex }

        private var digit: UInt8? {
            guard index < bytes.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
                return nil
            }
            return bytes[index] - UInt8(ascii: "0")
        }

        mutating func take(_ character: Unicode.Scalar) -> Bool {
            guard index < bytes.endIndex, bytes[index] == UInt8(ascii: character) else { return false }
            bytes.formIndex(after: &index)
            return true
        }

        /// Exactly `count` digits, as a number.
        mutating func digits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let digit else { return nil }
                value = value * 10 + Int(digit)
                bytes.formIndex(after: &index)
            }
            return value
        }

        /// One or more digits, as written.
        mutating func digitRun() -> String? {
            let start = index
            while digit != nil { bytes.formIndex(after: &index) }
            return index > start ? String(Substring(bytes[start..<index])) : nil
        }
    }

    /// The value for the day a picked date falls on in the person's calendar.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The value for an instant, in UTC and to the millisecond, as the server and the core write one.
    public static func instant(_ date: Date) -> String {
        // The format cuts the fraction, so a Date held as .12299999 would read .122: the milliseconds are rounded here
        // and written from the whole-second part and the milliseconds.
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = Date(timeIntervalSince1970: Double(milliseconds.floorDiv(1000)))
        let whole = seconds.formatted(Date.ISO8601FormatStyle())
        let fraction = String(format: "%03d", Int(milliseconds - milliseconds.floorDiv(1000) * 1000))
        return String(whole.dropLast()) + "." + fraction + "Z"
    }

    /// The day's midnight in UTC.
    ///
    /// The contract's days are the proleptic Gregorian calendar of years 0000 to 9999, which Foundation's Gregorian
    /// calendar is not (it counts the Julian calendar before 1582), so the day is checked and placed by arithmetic.
    private static func utcMidnight(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...lengths[month - 1]).contains(day) else { return nil }
        // Days since 1970-01-01, counted from a year starting in March so that the leap day ends its year.
        let shifted = month <= 2 ? year - 1 : year
        let era = shifted >= 0 ? shifted / 400 : (shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Date(timeIntervalSince1970: TimeInterval((era * 146_097 + dayOfEra - 719_468) * 86_400))
    }

    /// The start of a day on the calendar's clock.
    private static func startOfDay(_ year: Int, _ month: Int, _ day: Int, in zone: TimeZone) -> Date? {
        guard let midnight = utcMidnight(year, month, day) else { return nil }
        let guess = midnight.addingTimeInterval(-TimeInterval(zone.secondsFromGMT(for: midnight)))
        return midnight.addingTimeInterval(-TimeInterval(zone.secondsFromGMT(for: guess)))
    }
}

extension Int64 {
    fileprivate func floorDiv(_ divisor: Int64) -> Int64 {
        let quotient = self / divisor
        return self % divisor < 0 ? quotient - 1 : quotient
    }
}
