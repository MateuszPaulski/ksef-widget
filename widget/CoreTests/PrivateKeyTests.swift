import XCTest
@testable import KsefCore

final class PrivateKeyTests: XCTestCase {
    private let readFailure = "Nie można odczytać klucza prywatnego (złe hasło lub format): "

    func testDecryptsEverySupportedFixtureKey() throws {
        let fixture = try Fixtures.json("keys.json", as: KeysFixture.self)
        let dir = try temporaryDirectory()
        for entry in fixture.keys where entry.expect == "ok" {
            let key = try decryptPrivateKey(pem: entry.keyPem, password: entry.password)
            switch (key, entry.certificate) {
            case (.rsa, "rsa"), (.ec, "ec"): break
            default: XCTFail("\(entry.name): wrong key kind \(key)")
            }

            let certificateURL = dir.appendingPathComponent("\(entry.name).crt")
            let keyURL = dir.appendingPathComponent("\(entry.name).key")
            try XCTUnwrap(fixture.certificates[entry.certificate]).write(to: certificateURL, atomically: true, encoding: .utf8)
            try entry.keyPem.write(to: keyURL, atomically: true, encoding: .utf8)
            XCTAssertNoThrow(
                try loadCredentials(certificateURL: certificateURL, keyURL: keyURL, password: entry.password),
                entry.name
            )
        }
    }

    func testRejectsPbes1WithItsOid() throws {
        let fixture = try Fixtures.json("keys.json", as: KeysFixture.self)
        let entry = try XCTUnwrap(fixture.keys.first { $0.name == "pbes1-3des-ec" })
        XCTAssertThrowsError(try decryptPrivateKey(pem: entry.keyPem, password: entry.password)) {
            XCTAssertEqual(
                $0 as? KsefError,
                KsefError(message: "Nieobsługiwany algorytm szyfrowania klucza: 1.2.840.113549.1.12.1.3 (pbeWithSHAAnd3-KeyTripleDES-CBC). Obsługiwane: PBES2 z PBKDF2 (HMAC-SHA1, SHA224, SHA256, SHA384, SHA512) i AES-128/192/256-CBC.")
            )
        }
    }

    func testWrongPassword() throws {
        let fixture = try Fixtures.json("keys.json", as: KeysFixture.self)
        let entry = try XCTUnwrap(fixture.keys.first { $0.name == "libressl-sha1-aes256-ec" })
        XCTAssertThrowsError(try decryptPrivateKey(pem: entry.keyPem, password: "wrong")) {
            XCTAssertEqual($0 as? KsefError, KsefError(message: readFailure + "odszyfrowanie nie powiodło się"))
        }
    }

    func testNotAnEncryptedKey() {
        let pem = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"
        XCTAssertThrowsError(try decryptPrivateKey(pem: pem, password: "x")) {
            XCTAssertEqual(
                $0 as? KsefError,
                KsefError(message: readFailure + "oczekiwano -----BEGIN ENCRYPTED PRIVATE KEY-----")
            )
        }
    }

    func testGarbageInsideThePem() {
        let pem = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----"
        XCTAssertThrowsError(try decryptPrivateKey(pem: pem, password: "x")) {
            XCTAssertEqual($0 as? KsefError, KsefError(message: readFailure + "uszkodzona struktura PKCS#8"))
        }
    }
}
