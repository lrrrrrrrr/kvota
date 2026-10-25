import Foundation

/// Fast parser for the ISO-8601 timestamps the CLIs write
/// (`2026-10-25T08:15:30.123Z`). Falls back to `ISO8601DateFormatter` for anything unusual.
public enum Timestamp {
    public static func parse(_ string: String) -> Date? {
        var copy = string
        if let fast = copy.withUTF8({ parse(bytes: $0) }) {
            return fast
        }
        return fallback(string)
    }

    static func parse(bytes b: UnsafeBufferPointer<UInt8>) -> Date? {
        // YYYY-MM-DDTHH:MM:SS is 19 bytes.
        guard b.count >= 19, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x20, b[13] == 0x3A, b[16] == 0x3A else {
            return nil
        }
        func digits(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for i in start..<(start + length) {
                let c = b[i]
                guard c >= 0x30, c <= 0x39 else { return nil }
                value = value * 10 + Int(c - 0x30)
            }
            return value
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < b.count, b[index] == 0x2E {
            index += 1
            var scale = 0.1
            while index < b.count, b[index] >= 0x30, b[index] <= 0x39 {
                fraction += Double(b[index] - 0x30) * scale
                scale /= 10
                index += 1
            }
        }

        var offsetSeconds = 0
        if index < b.count {
            switch b[index] {
            case 0x5A, 0x7A: // Z
                index += 1
            case 0x2B, 0x2D: // + or -
                let sign = b[index] == 0x2B ? 1 : -1
                guard index + 3 <= b.count, let oh = digits(index + 1, 2) else { return nil }
                var om = 0
                if index + 6 <= b.count, b[index + 3] == 0x3A, let m = digits(index + 4, 2) {
                    om = m
                    index += 6
                } else if index + 5 <= b.count, let m = digits(index + 3, 2) {
                    om = m
                    index += 5
                } else {
                    index += 3
                }
                offsetSeconds = sign * (oh * 3600 + om * 60)
            default:
                return nil
            }
        }
        guard index == b.count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func fallback(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
