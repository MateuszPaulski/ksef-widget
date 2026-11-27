import XCTest
@testable import KsefCore

final class CredentialInstallTests: XCTestCase {
    private var home: URL!
    private var paths: AppPaths!
    private var source: URL!
    private var files: TestCredentialFiles!

    override func setUpWithError() throws {
        let root = try temporaryDirectory()
        home = root.appendingPathComponent("home")
        source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        paths = AppPaths(home: home)
        files = try TestCredentials.make(nip: randomNip(), keyType: .rsa, in: source)
    }

    private func install(_ files: TestCredentialFiles, password: String? = nil, secrets: FakeSecretStore) throws {
        try installCredentials(
            certificate: files.certificateURL, key: files.keyURL, password: password ?? files.password, paths: paths, secrets: secrets
        )
    }

    func testInstallCopiesBothFilesAndSavesThePassword() throws {
        let secrets = FakeSecretStore()

        try install(files, secrets: secrets)

        XCTAssertEqual(try Data(contentsOf: paths.certificate), try Data(contentsOf: files.certificateURL))
        XCTAssertEqual(try Data(contentsOf: paths.key), try Data(contentsOf: files.keyURL))
        XCTAssertEqual(try permissions(paths.certificate), 0o600)
        XCTAssertEqual(try permissions(paths.key), 0o600)
        XCTAssertEqual(try permissions(paths.appFolder), 0o700)
        XCTAssertEqual(secrets.saved, [files.password])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: paths.appFolder.path).sorted(), ["ksef-auth.crt", "ksef-auth.key"]
        )
    }

    func testStagedFilesAreCreatedPrivateEvenWithAnOpenUmask() throws {
        let previous = umask(0)
        defer { umask(previous) }
        let url = paths.appFolder.appendingPathComponent("staged.new")

        try stagePrivately(Data("secret".utf8), at: url)

        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try permissions(paths.appFolder), 0o700)
    }

    func testInstallRejectsWrongPasswordAndLeavesNothing() throws {
        let secrets = FakeSecretStore()

        XCTAssertThrowsError(try install(files, password: "wrong", secrets: secrets)) {
            XCTAssertTrue(
                errorMessage($0).hasPrefix("Nie można odczytać klucza prywatnego (złe hasło lub format)"), errorMessage($0)
            )
        }

        XCTAssertFalse(exists(paths.appFolder))
        XCTAssertTrue(secrets.saved.isEmpty)
    }

    func testInstallRejectsUnsupportedAlgorithm() throws {
        let fixture = try Fixtures.json("keys.json", as: KeysFixture.self)
        let entry = try XCTUnwrap(fixture.keys.first { $0.name == "pbes1-3des-ec" })
        let certificate = source.appendingPathComponent("pbes1.crt")
        let key = source.appendingPathComponent("pbes1.key")
        try XCTUnwrap(fixture.certificates[entry.certificate]).write(to: certificate, atomically: true, encoding: .utf8)
        try entry.keyPem.write(to: key, atomically: true, encoding: .utf8)
        let secrets = FakeSecretStore()

        XCTAssertThrowsError(
            try installCredentials(certificate: certificate, key: key, password: entry.password, paths: paths, secrets: secrets)
        ) {
            XCTAssertTrue(errorMessage($0).hasPrefix("Nieobsługiwany algorytm szyfrowania klucza: 1.2.840.113549.1.12.1.3"), errorMessage($0))
        }

        XCTAssertFalse(exists(paths.appFolder))
        XCTAssertTrue(secrets.saved.isEmpty)
    }

    func testInstallRejectsAMismatchedPair() throws {
        let other = try TestCredentials.make(nip: randomNip(), keyType: .ec, in: source)
        let secrets = FakeSecretStore()

        XCTAssertThrowsError(
            try installCredentials(certificate: files.certificateURL, key: other.keyURL, password: other.password, paths: paths, secrets: secrets)
        ) {
            XCTAssertEqual(errorMessage($0), "Klucz prywatny nie pasuje do certyfikatu")
        }

        XCTAssertFalse(exists(paths.appFolder))
        XCTAssertTrue(secrets.saved.isEmpty)
    }

    func testReinstallReplacesTheCopies() throws {
        let secrets = FakeSecretStore()
        try install(files, secrets: secrets)
        let next = try TestCredentials.make(nip: randomNip(), keyType: .ec, in: source)

        try install(next, secrets: secrets)

        XCTAssertEqual(try Data(contentsOf: paths.certificate), try Data(contentsOf: next.certificateURL))
        XCTAssertEqual(try Data(contentsOf: paths.key), try Data(contentsOf: next.keyURL))
        XCTAssertEqual(try permissions(paths.key), 0o600)
        XCTAssertEqual(secrets.saved, [files.password, next.password])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: paths.appFolder.path).sorted(), ["ksef-auth.crt", "ksef-auth.key"]
        )
    }

    func testAFailedReinstallKeepsThePreviousCopies() throws {
        let secrets = FakeSecretStore()
        try install(files, secrets: secrets)
        let before = try Data(contentsOf: paths.key)

        XCTAssertThrowsError(try install(files, password: "wrong", secrets: secrets))

        XCTAssertEqual(try Data(contentsOf: paths.key), before)
        XCTAssertEqual(secrets.saved, [files.password])
    }
}
