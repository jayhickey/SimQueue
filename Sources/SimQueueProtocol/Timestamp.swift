// SPDX-License-Identifier: MIT

import Foundation

/// A point in time on the wire. Stored as Unix epoch seconds (the database keeps epoch),
/// encoded in JSON as an RFC 3339 UTC string: `2026-10-19T21:45:00Z`, with milliseconds
/// only when they're non-zero (`2026-10-19T21:45:00.250Z`). Decoding accepts any RFC 3339
/// timestamp (`Z` or a numeric offset, any fraction) and, for older clients, a bare number
/// of epoch seconds.
///
/// Formatting and parsing are done by hand (proleptic Gregorian, no leap seconds) so the
/// result is identical on macOS and Linux and doesn't depend on locale or formatter state.
public struct Timestamp: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var epochSeconds: Double

    public init(_ epochSeconds: Double) {
        self.epochSeconds = epochSeconds
    }

    public init?(_ epochSeconds: Double?) {
        guard let epochSeconds else { return nil }
        self.epochSeconds = epochSeconds
    }

    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool { lhs.epochSeconds < rhs.epochSeconds }

    public var date: Date { Date(timeIntervalSince1970: epochSeconds) }

    public var description: String { rfc3339 }

    /// `YYYY-MM-DDTHH:MM:SS[.mmm]Z`, rounded to the millisecond.
    public var rfc3339: String {
        let totalMillis = Int64((epochSeconds * 1000).rounded())
        let millis = Int(((totalMillis % 1000) + 1000) % 1000)
        let seconds = (totalMillis - Int64(millis)) / 1000
        let days = Int64((Double(seconds) / 86_400).rounded(.down))
        let secondOfDay = Int(seconds - days * 86_400)
        let (year, month, day) = Self.civil(fromDays: days)
        var text =
            Self.pad(year, 4) + "-" + Self.pad(month, 2) + "-" + Self.pad(day, 2) + "T"
            + Self.pad(secondOfDay / 3600, 2) + ":" + Self.pad(secondOfDay % 3600 / 60, 2) + ":"
            + Self.pad(secondOfDay % 60, 2)
        if millis != 0 {
            text += "." + Self.pad(millis, 3)
        }
        return text + "Z"
    }

    /// Parses an RFC 3339 date-time (`T` or `t` or a space between date and time, `Z`/`z`
    /// or `±HH:MM`). Returns nil for anything else.
    public init?(rfc3339 text: String) {
        let bytes = Array(text.utf8)
        func number(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[start..<(start + count)] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        func byte(_ index: Int) -> UInt8? { index < bytes.count ? bytes[index] : nil }
        guard let year = number(0, 4), byte(4) == 0x2D, let month = number(5, 2), byte(7) == 0x2D,
            let day = number(8, 2), let separator = byte(10), [0x54, 0x74, 0x20].contains(separator),
            let hour = number(11, 2), byte(13) == 0x3A, let minute = number(14, 2), byte(16) == 0x3A,
            let second = number(17, 2)
        else { return nil }
        guard (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year), hour <= 23,
            minute <= 59, second <= 60
        else { return nil }
        var index = 19
        var fraction = 0.0
        if byte(index) == 0x2E {
            index += 1
            var scale = 0.1
            let start = index
            while let digit = byte(index), digit >= 0x30, digit <= 0x39 {
                fraction += Double(digit - 0x30) * scale
                scale /= 10
                index += 1
            }
            guard index > start else { return nil }
        }
        var offsetSeconds = 0
        switch byte(index) {
        case 0x5A, 0x7A:
            index += 1
        case 0x2B, 0x2D:
            guard let offsetHours = number(index + 1, 2), byte(index + 3) == 0x3A,
                let offsetMinutes = number(index + 4, 2), offsetHours <= 23, offsetMinutes <= 59
            else { return nil }
            offsetSeconds = (offsetHours * 3600 + offsetMinutes * 60) * (byte(index) == 0x2D ? -1 : 1)
            index += 6
        default:
            return nil
        }
        guard index == bytes.count else { return nil }
        let days = Self.days(fromCivil: year, month, day)
        let seconds = Double(days * 86_400 + Int64(hour * 3600 + minute * 60 + min(second, 59) - offsetSeconds))
        self.epochSeconds = seconds + fraction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard let parsed = Timestamp(rfc3339: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not an RFC 3339 timestamp: \(text)")
            }
            self = parsed
        } else {
            self.init(try container.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rfc3339)
    }

    /// For tables: month, day and 12-hour time in `timeZone` (this Mac's by default), e.g.
    /// `Oct 22, 12:43 PM`. Always English month names and AM/PM so the column reads the same
    /// on every Mac; JSON keeps `rfc3339`.
    public func shortLocal(timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    /// `shortLocal`, or `-` when there is no time (a job that hasn't started yet).
    public static func shortLocalOrDash(_ timestamp: Timestamp?, timeZone: TimeZone = .current) -> String {
        timestamp?.shortLocal(timeZone: timeZone) ?? "-"
    }

    // MARK: - Calendar math (Howard Hinnant's days_from_civil / civil_from_days)

    static func days(fromCivil year: Int, _ month: Int, _ day: Int) -> Int64 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let m = Int64(month)
        let dayOfYear = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(day) - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civil(fromDays days: Int64) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (Int(year), Int(month), Int(day))
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}
