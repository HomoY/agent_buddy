import Foundation

public enum Dates {
    private static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// ISO 8601 timestamps with any number of fractional digits (Claude writes
    /// microseconds), or a bare UTC day such as Copilot's `2026-11-01`.
    public static func parse(_ text: String?) -> Date? {
        if let text, let date = internetTime(text) {
            return date
        }
        guard var text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        var fraction = 0.0
        if let tee = text.firstIndex(of: "T"), let dot = text[tee...].firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isASCII, text[end].isNumber {
                end = text.index(after: end)
            }
            fraction = Double("0" + String(text[dot..<end])) ?? 0
            text.removeSubrange(dot..<end)
        }
        if let date = internet.date(from: text) {
            return date.addingTimeInterval(fraction)
        }
        if text.count == 10, let date = day.date(from: text) {
            return date
        }
        return nil
    }

    /// The usual form, "2026-10-28T09:41:05.123456Z" or with "+08:00", read
    /// directly (logs have a time on every line, and a formatter is slow): the
    /// same date the formatter makes. Nil for anything else, left to the formatter.
    static func internetTime(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { bytes -> Date? in
            let count = bytes.count
            guard count >= 20 else { return nil }
            func number(_ from: Int, _ digits: Int) -> Int? {
                var value = 0
                for index in from..<from + digits {
                    let byte = bytes[index]
                    guard byte >= 0x30, byte <= 0x39 else { return nil }
                    value = value * 10 + Int(byte - 0x30)
                }
                return value
            }
            guard let year = number(0, 4), bytes[4] == 0x2D, let month = number(5, 2), bytes[7] == 0x2D, let day = number(8, 2),
                  bytes[10] == 0x54, let hour = number(11, 2), bytes[13] == 0x3A, let minute = number(14, 2), bytes[16] == 0x3A,
                  let second = number(17, 2),
                  year >= 1, (1...12).contains(month), hour < 24, minute < 60, second < 60
            else { return nil }
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
            guard day >= 1, day <= days else { return nil }
            var index = 19
            var fraction = 0.0
            if bytes[index] == 0x2E {
                var end = index + 1
                while end < count, bytes[end] >= 0x30, bytes[end] <= 0x39 {
                    end += 1
                }
                guard end > index + 1 else { return nil }
                // As the formatter's way does it: "0.123456" read as a number.
                fraction = Double("0" + String(decoding: UnsafeBufferPointer(rebasing: bytes[index..<end]), as: UTF8.self)) ?? 0
                index = end
            }
            var offset = 0
            if index == count - 1, bytes[index] == 0x5A {
                offset = 0
            } else if index == count - 6, bytes[index] == 0x2B || bytes[index] == 0x2D, bytes[index + 3] == 0x3A,
                      let hours = number(index + 1, 2), let minutes = number(index + 4, 2), hours < 24, minutes < 60 {
                offset = (hours * 3600 + minutes * 60) * (bytes[index] == 0x2D ? -1 : 1)
            } else {
                return nil
            }
            // Days since 1970 of the civil date (Howard Hinnant's days_from_civil).
            let shifted = month <= 2 ? year - 1 : year
            let era = shifted / 400
            let yearOfEra = shifted - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let epochDays = era * 146_097 + dayOfEra - 719_468
            let seconds = epochDays * 86_400 + hour * 3600 + minute * 60 + second - offset
            return Date(timeIntervalSince1970: TimeInterval(seconds)).addingTimeInterval(fraction)
        }
    }

    /// Seconds, or milliseconds, since 1970.
    public static func epoch(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }
}
