import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var nip: String
    public var environment: KsefEnvironment
    public var startDate: String  // YYYY-MM-DD
    public var dataDir: String
    public var verified: Bool

    public init(nip: String, environment: KsefEnvironment, startDate: String, dataDir: String, verified: Bool) {
        self.nip = nip
        self.environment = environment
        self.startDate = startDate
        self.dataDir = dataDir
        self.verified = verified
    }
}

private let nipWeights = [6, 5, 7, 2, 3, 4, 5, 6, 7]

/// ASCII digits only: Swift's `isNumber` and regex `\d` also accept other scripts.
private func asciiDigits(_ text: String) -> [Int]? {
    let bytes = Array(text.utf8)
    return bytes.allSatisfy { (48...57).contains($0) } ? bytes.map { Int($0) - 48 } : nil
}

func isValidNip(_ nip: String) -> Bool {
    // The OpenAPI pattern: first digit 1-9, digits 2-3 not both 0.
    guard let digits = asciiDigits(nip), digits.count == 10, digits[0] != 0, !(digits[1] == 0 && digits[2] == 0) else { return false }
    let sum = zip(nipWeights, digits).reduce(0) { $0 + $1.0 * $1.1 }
    return sum % 11 == digits[9]
}

private func isValidStartDate(_ value: String, today: Date) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.map(\.count) == [4, 2, 2], parts.allSatisfy({ asciiDigits(String($0)) != nil }),
          let millis = KsefTime.millis("\(value)T00:00:00Z")
    else { return false }
    // KsefTime accepts day 31 of any month; a real date survives the round trip.
    let normalized = KsefTime.iso(millis: millis).prefix(10)
    return normalized == value && value <= KsefTime.iso(today).prefix(10)
}

extension Settings {
    func validate(today: Date) throws {
        guard isValidNip(nip) else { throw KsefError("NIP musi mieć 10 cyfr i poprawną sumę kontrolną") }
        guard isValidStartDate(startDate, today: today) else {
            throw KsefError("Data początkowa musi mieć format RRRR-MM-DD i nie może być z przyszłości")
        }
        guard dataDir.hasPrefix("/") else { throw KsefError("Folder faktur musi być ścieżką bezwzględną") }
    }
}

public enum SettingsFile {
    /// Nil when the file does not exist; a file that exists but is unusable throws.
    public static func load(_ url: URL) throws -> Settings? {
        guard let data = try readIfExists(url) else { return nil }
        let settings: Settings
        do {
            settings = try JSONDecoder().decode(Settings.self, from: data)
            try settings.validate(today: Date())
        } catch {
            throw KsefError("Uszkodzony plik ustawień: \(errorMessage(error))")
        }
        return settings
    }

    public static func save(_ settings: Settings, to url: URL) throws {
        let json = JSONValue.object([
            ("nip", .string(settings.nip)),
            ("environment", .string(settings.environment.rawValue)),
            ("startDate", .string(settings.startDate)),
            ("dataDir", .string(settings.dataDir)),
            ("verified", .bool(settings.verified)),
        ])
        try writePrivately(Data((json.pretty() + "\n").utf8), to: url)
    }
}
