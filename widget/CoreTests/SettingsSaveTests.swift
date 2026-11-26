import XCTest
@testable import KsefCore

private struct FailingSecretStore: SecretStore {
    func readKeyPassword() throws -> String { throw KsefError("unused") }
    func saveKeyPassword(_ password: String) throws { throw KsefError("Pęk kluczy: odmowa (OSStatus -1)") }
}

final class SettingsSaveTests: XCTestCase {
    private let today = instant("2026-11-26T12:00:00Z")
    private let missingInputs = "Wybierz certyfikat i klucz oraz wpisz hasło klucza."
    private var paths: AppPaths!
    private var files: TestCredentialFiles!
    private var dataDir: String!

    override func setUpWithError() throws {
        let root = try temporaryDirectory()
        paths = AppPaths(home: root.appendingPathComponent("home"))
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        files = try TestCredentials.make(nip: randomNip(), keyType: .rsa, in: source)
        dataDir = root.appendingPathComponent("invoices").path
    }

    private func draft(
        nip: String = "5265877635", environment: KsefEnvironment = .prod, startDate: String = "2026-02-01",
        withFiles: Bool = true, password: String? = nil
    ) -> SettingsDraft {
        SettingsDraft(
            nip: nip, environment: environment, startDate: startDate, dataDir: dataDir,
            certificate: withFiles ? files.certificateURL : nil, key: withFiles ? files.keyURL : nil,
            password: password ?? (withFiles ? files.password : "")
        )
    }

    private func save(
        _ draft: SettingsDraft, previous: Settings? = nil, secrets: SecretStore = FakeSecretStore()
    ) throws -> Settings {
        try saveSettings(draft, previous: previous, paths: paths, secrets: secrets, today: today)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func message(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            return errorMessage(error)
        }
    }

    func testSavesAnUnverifiedSettingsAfterInstallingTheCredentials() throws {
        let secrets = FakeSecretStore()

        let saved = try save(draft(), secrets: secrets)

        XCTAssertEqual(saved, Settings(nip: "5265877635", environment: .prod, startDate: "2026-02-01", dataDir: dataDir, verified: false))
        XCTAssertEqual(try SettingsFile.load(paths.settings), saved)
        XCTAssertEqual(secrets.saved, [files.password])
        XCTAssertTrue(exists(paths.certificate) && exists(paths.key))
        XCTAssertTrue(exists(URL(fileURLWithPath: dataDir)))
    }

    func testKeychainFailureIsShownAndWritesNoSettings() {
        let text = message { _ = try save(draft(), secrets: FailingSecretStore()) }

        XCTAssertEqual(text, "Pęk kluczy: odmowa (OSStatus -1)")
        XCTAssertFalse(exists(paths.settings))
    }

    func testWrongPasswordWritesNothing() {
        let text = message { _ = try save(draft(password: "wrong")) }

        XCTAssertTrue(try XCTUnwrap(text).hasPrefix("Nie można odczytać klucza prywatnego (złe hasło lub format)"))
        XCTAssertFalse(exists(paths.appFolder))
    }

    func testInvalidFieldsAreRejectedBeforeAnythingIsInstalled() {
        XCTAssertEqual(
            message { _ = try save(draft(nip: "5265877636")) }, "NIP musi mieć 10 cyfr i poprawną sumę kontrolną"
        )
        XCTAssertEqual(
            message { _ = try save(draft(startDate: "2026-11-27")) },
            "Data początkowa musi mieć format RRRR-MM-DD i nie może być z przyszłości"
        )
        XCTAssertFalse(exists(paths.appFolder))
    }

    func testPartialCredentialInputIsRejected() {
        var certificateOnly = draft(withFiles: false)
        certificateOnly.certificate = files.certificateURL
        XCTAssertEqual(message { _ = try save(certificateOnly) }, missingInputs)
        XCTAssertEqual(message { _ = try save(draft(withFiles: false, password: "x")) }, missingInputs)
        XCTAssertFalse(exists(paths.appFolder))
    }

    func testStoredCredentialsAreRequiredWhenNothingIsEntered() {
        XCTAssertEqual(message { _ = try save(draft(withFiles: false)) }, missingInputs)
    }

    func testKeepsStoredCredentialsAndVerifiedWhenIdentityIsUnchanged() throws {
        let secrets = FakeSecretStore()
        let first = try save(draft(), secrets: secrets)
        var verified = first
        verified.verified = true

        let second = try save(draft(startDate: "2026-03-01", withFiles: false), previous: verified, secrets: secrets)

        XCTAssertTrue(second.verified)
        XCTAssertEqual(second.startDate, "2026-03-01")
        XCTAssertEqual(secrets.saved.count, 1)
    }

    func testChangingNipEnvironmentOrCredentialsResetsVerified() throws {
        let secrets = FakeSecretStore()
        var verified = try save(draft(), secrets: secrets)
        verified.verified = true

        XCTAssertFalse(try save(draft(nip: "1234563218", withFiles: false), previous: verified, secrets: secrets).verified)
        XCTAssertFalse(try save(draft(environment: .test, withFiles: false), previous: verified, secrets: secrets).verified)
        XCTAssertFalse(try save(draft(), previous: verified, secrets: secrets).verified)
    }

    func testStartDateTextIsTheWarsawCalendarDay() throws {
        XCTAssertEqual(startDateText(instant("2026-11-25T23:30:00Z")), "2026-11-26")
        XCTAssertEqual(startDateText(instant("2026-07-01T21:59:00Z")), "2026-07-01")
        XCTAssertEqual(startDateText(instant("2026-07-01T22:00:00Z")), "2026-07-02")
        for text in ["2026-11-26", "2026-07-01", "2026-03-29"] {
            XCTAssertEqual(startDateText(try XCTUnwrap(startDate(fromText: text))), text)
        }
        XCTAssertNil(startDate(fromText: "garbage"))
    }

    func testConnectionCheckTexts() {
        let counts = DryRunCounts(listed: 3, notSaved: 1)
        let ok = RunSummary(startedAt: today, status: .complete, reason: nil, failureKey: nil, saved: [], checked: counts)
        let failed = RunSummary(startedAt: today, status: .failed, reason: "Brak połączenia z KSeF: x", failureKey: "k", saved: [], checked: nil)

        XCTAssertEqual(connectionCheckResult(ok).text, "Połączenie działa. Faktury w pierwszym oknie: 3, jeszcze niezapisane: 1.")
        XCTAssertFalse(connectionCheckResult(ok).isError)
        XCTAssertEqual(connectionCheckResult(failed).text, "Błąd: Brak połączenia z KSeF: x")
        XCTAssertTrue(connectionCheckResult(failed).isError)
    }
}
