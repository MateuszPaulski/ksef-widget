import XCTest
@testable import KsefCore

final class SettingsTests: XCTestCase {
    private let today = instant("2026-11-26T12:00:00Z")
    private let nipMessage = "NIP musi mieć 10 cyfr i poprawną sumę kontrolną"
    private let startDateMessage = "Data początkowa musi mieć format RRRR-MM-DD i nie może być z przyszłości"

    private func settings(
        nip: String = "5265877635", environment: KsefEnvironment = .prod, startDate: String = "2026-02-01",
        dataDir: String = "/tmp/x", verified: Bool = true
    ) -> Settings {
        Settings(nip: nip, environment: environment, startDate: startDate, dataDir: dataDir, verified: verified)
    }

    private func validationMessage(_ settings: Settings) -> String? {
        do {
            try settings.validate(today: today)
            return nil
        } catch {
            return errorMessage(error)
        }
    }

    func testAcceptsAValidSettings() {
        XCTAssertNil(validationMessage(settings()))
    }

    func testAcceptsAStartDateEqualToToday() {
        XCTAssertNil(validationMessage(settings(startDate: "2026-11-26")))
    }

    func testRejectsAnInvalidNipChecksum() {
        XCTAssertEqual(validationMessage(settings(nip: "5265877636")), nipMessage)
    }

    func testRejectsAStartDateWithAnImpossibleMonth() {
        XCTAssertEqual(validationMessage(settings(startDate: "2026-13-01")), startDateMessage)
    }

    func testRejectsAStartDateInTheWrongFormat() {
        XCTAssertEqual(validationMessage(settings(startDate: "1.02.2026")), startDateMessage)
    }

    func testRejectsAFutureStartDate() {
        XCTAssertEqual(validationMessage(settings(startDate: "2026-11-27")), startDateMessage)
    }

    func testRejectsADayThatDoesNotExist() {
        XCTAssertEqual(validationMessage(settings(startDate: "2026-02-30")), startDateMessage)
    }

    func testRejectsADateWrittenWithNonAsciiDigits() {
        XCTAssertEqual(validationMessage(settings(startDate: "２０２６-02-01")), startDateMessage)
    }

    func testRejectsARelativeDataDir() {
        XCTAssertEqual(validationMessage(settings(dataDir: "data")), "Folder faktur musi być ścieżką bezwzględną")
    }

    func testIsValidNip() {
        XCTAssertTrue(isValidNip("5265877635"))
        XCTAssertFalse(isValidNip("5265877636"))
        XCTAssertFalse(isValidNip("526587763"))
        XCTAssertFalse(isValidNip("0265877635"))
    }

    func testIsValidNipRejectsNonAsciiDigits() {
        XCTAssertFalse(isValidNip("５２６５８７７６３５"))
    }

    func testCorruptSettingsFiles() throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent("settings.json")
        let valid = #"{"nip":"5265877635","environment":"prod","startDate":"2026-02-01","dataDir":"/tmp/x","verified":true}"#
        let corrupt = [
            "null", #""x""#, "[]", "{", "",
            #"{"nip":5265877635,"environment":"prod","startDate":"2026-02-01","dataDir":"/tmp/x","verified":true}"#,
            #"{"nip":"5265877635","environment":"production","startDate":"2026-02-01","dataDir":"/tmp/x","verified":true}"#,
            #"{"nip":"5265877635","environment":"prod","startDate":"2026-02-01","dataDir":42,"verified":true}"#,
            valid.replacingOccurrences(of: "5265877635", with: "5265877636"),
        ]
        for text in corrupt {
            try text.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try SettingsFile.load(file), text) {
                XCTAssertTrue(errorMessage($0).hasPrefix("Uszkodzony plik ustawień: "), "\(text) -> \(errorMessage($0))")
            }
        }
        try valid.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SettingsFile.load(file), settings())
    }

    func testAValidShapeWithABadNipSaysWhy() throws {
        let file = try temporaryDirectory().appendingPathComponent("settings.json")
        try #"{"nip":"1","environment":"prod","startDate":"2026-02-01","dataDir":"/tmp/x","verified":true}"#
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SettingsFile.load(file)) {
            XCTAssertEqual(errorMessage($0), "Uszkodzony plik ustawień: \(nipMessage)")
        }
    }

    func testMissingFileIsNil() throws {
        XCTAssertNil(try SettingsFile.load(try temporaryDirectory().appendingPathComponent("settings.json")))
    }

    func testSaveRoundTripsWithPermissions() throws {
        let folder = try temporaryDirectory().appendingPathComponent("app")
        let file = folder.appendingPathComponent("settings.json")
        let original = settings(environment: .test, verified: false)

        try SettingsFile.save(original, to: file)

        XCTAssertEqual(try SettingsFile.load(file), original)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try permissions(folder), 0o700)
    }

    func testSaveReplacesAnExistingFile() throws {
        let file = try temporaryDirectory().appendingPathComponent("app/settings.json")
        try SettingsFile.save(settings(verified: false), to: file)
        try SettingsFile.save(settings(verified: true), to: file)
        XCTAssertEqual(try SettingsFile.load(file)?.verified, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["settings.json"])
    }

    func testMissingPasswordMessage() {
        XCTAssertEqual(
            KeychainSecretStore.missingPasswordMessage,
            "Brak hasła klucza w Pęku kluczy (usługa local.ksef-daily-fetch.KsefWidget, konto key-password)"
        )
    }

    func testAppPathsLiveUnderTheGivenHome() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let paths = AppPaths(home: home)
        let appFolder = "/tmp/home/Library/Application Support/local.ksef-daily-fetch.KsefWidget"
        XCTAssertEqual(paths.appFolder.path, appFolder)
        XCTAssertEqual(paths.settings.path, "\(appFolder)/settings.json")
        XCTAssertEqual(paths.certificate.path, "\(appFolder)/ksef-auth.crt")
        XCTAssertEqual(paths.key.path, "\(appFolder)/ksef-auth.key")
        XCTAssertEqual(paths.snapshot.path, "/tmp/home/Library/Application Support/ksef-daily-fetch/widget.json")
        XCTAssertEqual(paths.defaultDataDir.path, "/tmp/home/Documents/KSeF")
        XCTAssertEqual(paths.legacyLaunchAgent.path, "/tmp/home/Library/LaunchAgents/local.ksef-daily-fetch.plist")
    }
}
