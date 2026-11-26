import Foundation

private let missingCredentialInputs = "Wybierz certyfikat i klucz oraz wpisz hasło klucza."

public struct SettingsDraft: Sendable {
    public var nip: String
    public var environment: KsefEnvironment
    public var startDate: String
    public var dataDir: String
    public var certificate: URL?
    public var key: URL?
    public var password: String

    public init(
        nip: String, environment: KsefEnvironment, startDate: String, dataDir: String,
        certificate: URL?, key: URL?, password: String
    ) {
        self.nip = nip
        self.environment = environment
        self.startDate = startDate
        self.dataDir = dataDir
        self.certificate = certificate
        self.key = key
        self.password = password
    }
}

/// The save flow of the settings window. `settings.json` is written last, so any earlier failure leaves it unchanged.
public func saveSettings(
    _ draft: SettingsDraft, previous: Settings?, paths: AppPaths, secrets: SecretStore, today: Date
) throws -> Settings {
    var settings = Settings(
        nip: draft.nip, environment: draft.environment, startDate: draft.startDate, dataDir: draft.dataDir, verified: false
    )
    try settings.validate(today: today)

    let enteredCredentials = draft.certificate != nil || draft.key != nil || !draft.password.isEmpty
    if enteredCredentials {
        guard let certificate = draft.certificate, let key = draft.key, !draft.password.isEmpty else {
            throw KsefError(missingCredentialInputs)
        }
        try installCredentials(certificate: certificate, key: key, password: draft.password, paths: paths, secrets: secrets)
    } else {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.certificate.path), fileManager.fileExists(atPath: paths.key.path) else {
            throw KsefError(missingCredentialInputs)
        }
    }

    try FileManager.default.createDirectory(at: URL(fileURLWithPath: draft.dataDir), withIntermediateDirectories: true)

    if let previous, previous.verified, !enteredCredentials, previous.nip == draft.nip, previous.environment == draft.environment {
        settings.verified = true
    }
    try SettingsFile.save(settings, to: paths.settings)
    return settings
}

/// UTC midnight of `text`: the same Warsaw calendar day in winter and summer time.
public func startDate(fromText text: String) -> Date? {
    KsefTime.millis("\(text)T00:00:00Z").map { Date(timeIntervalSince1970: Double($0) / 1000) }
}

public func startDateText(_ date: Date) -> String { warsawDay(date) }

public func connectionCheckResult(_ summary: RunSummary) -> (text: String, isError: Bool) {
    if summary.status == .failed { return ("Błąd: \(summary.reason ?? "nieznany błąd")", true) }
    guard let counts = summary.checked else { return ("Połączenie działa.", false) }
    return ("Połączenie działa. Faktury w pierwszym oknie: \(counts.listed), jeszcze niezapisane: \(counts.notSaved).", false)
}
