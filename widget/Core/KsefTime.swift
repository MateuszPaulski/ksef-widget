import Foundation

/// KSeF instants as integer milliseconds, because Date's Double keeps sub-millisecond fractions
/// that JavaScript's Date.parse truncates.
enum KsefTime {
    static func millis(_ iso: String) -> Int64? {
        var cursor = Cursor(Array(iso.utf8))
        guard let year = cursor.number(digits: 4), cursor.skip("-"),
              let month = cursor.number(digits: 2), cursor.skip("-"),
              let day = cursor.number(digits: 2), cursor.skip("T"),
              let hour = cursor.number(digits: 2), cursor.skip(":"),
              let minute = cursor.number(digits: 2), cursor.skip(":"),
              let second = cursor.number(digits: 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60
        else { return nil }

        var milliseconds = 0
        if cursor.skip(".") {
            guard let fraction = cursor.fractionMillis() else { return nil }
            milliseconds = fraction
        }

        var offsetMinutes = 0
        if !cursor.skip("Z") {
            guard let sign = cursor.sign(), let offsetHour = cursor.number(digits: 2), cursor.skip(":"),
                  let offsetMinute = cursor.number(digits: 2)
            else { return nil }
            offsetMinutes = sign * (offsetHour * 60 + offsetMinute)
        }
        guard cursor.isAtEnd else { return nil }

        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + Int64(hour * 3600 + minute * 60 + second - offsetMinutes * 60)
        return seconds * 1000 + Int64(milliseconds)
    }

    static func iso(millis: Int64) -> String {
        let (seconds, remainder) = floorDivide(millis, 1000)
        let (days, secondOfDay) = floorDivide(seconds, 86_400)
        let (year, month, day) = civilFromDays(days)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            year, month, day, secondOfDay / 3600, secondOfDay % 3600 / 60, secondOfDay % 60, remainder
        )
    }

    static func iso(_ date: Date) -> String { iso(millis: millis(date)) }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    private struct Cursor {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { position == bytes.count }

        mutating func skip(_ character: Character) -> Bool {
            guard position < bytes.count, bytes[position] == character.asciiValue else { return false }
            position += 1
            return true
        }

        mutating func sign() -> Int? {
            if skip("+") { return 1 }
            if skip("-") { return -1 }
            return nil
        }

        // Digits beyond the third are dropped (truncation, as Date.parse does).
        mutating func fractionMillis() -> Int? {
            var value = 0
            var count = 0
            while position < bytes.count, (48...57).contains(bytes[position]) {
                if count < 3 { value = value * 10 + Int(bytes[position] - 48) }
                count += 1
                position += 1
            }
            guard count > 0 else { return nil }
            for _ in 0..<max(0, 3 - count) { value *= 10 }
            return value
        }

        mutating func number(digits count: Int) -> Int? {
            guard position + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[position..<position + count] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            position += count
            return value
        }
    }

    // Howard Hinnant's days_from_civil / civil_from_days.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = floorDivide(y, 400).0
        let yearOfEra = y - era * 400
        let dayOfYear = Int64((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1)
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int64) -> (Int, Int, Int) {
        let shifted = days + 719_468
        let era = floorDivide(shifted, 146_097).0
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = Int(dayOfYear - (153 * monthIndex + 2) / 5 + 1)
        let month = Int(monthIndex < 10 ? monthIndex + 3 : monthIndex - 9)
        let year = Int(yearOfEra + era * 400) + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> (Int64, Int) {
        var quotient = value / divisor
        var remainder = value % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, Int(remainder))
    }
}
