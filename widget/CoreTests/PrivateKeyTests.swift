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

    // A 31-byte scalar is what LibreSSL writes for about one EC key in 256.
    private let shortScalar = Array(1...31) as [UInt8]

    private var shortScalarKeyInfo: [UInt8] {
        der(0x30,
            der(0x02, [0])
                + der(0x30, derOID("1.2.840.10045.2.1") + derOID("1.2.840.10045.3.1.7"))
                + der(0x04, der(0x30, der(0x02, [1]) + der(0x04, shortScalar))))
    }

    func testDecryptsEveryPbkdf2PrfAndAesSizeAndAShortEcScalar() throws {
        for prf in TestPrf.allCases {
            for keySize in [16, 24, 32] {
                let pem = encryptedPem(privateKeyInfo: shortScalarKeyInfo, password: "pässwörd", prf: prf, keySize: keySize, declareKeyLength: keySize == 24)
                guard case .ec(let key) = try decryptPrivateKey(pem: pem, password: "pässwörd") else { return XCTFail("\(prf) \(keySize)") }
                XCTAssertEqual(key.rawRepresentation, Data([0] + shortScalar), "\(prf) \(keySize)")
            }
        }
    }

    func testNamesAnUnsupportedKdfAndCipher() {
        let scrypt = encryptedPem(privateKeyInfo: shortScalarKeyInfo, password: "x", kdfOID: "1.3.6.1.4.1.11591.4.11")
        XCTAssertThrowsError(try decryptPrivateKey(pem: scrypt, password: "x")) {
            XCTAssertTrue(errorMessage($0).hasPrefix("Nieobsługiwany algorytm szyfrowania klucza: 1.3.6.1.4.1.11591.4.11 (scrypt). "), errorMessage($0))
        }
        let tripleDes = encryptedPem(privateKeyInfo: shortScalarKeyInfo, password: "x", cipherOID: "1.2.840.113549.3.7")
        XCTAssertThrowsError(try decryptPrivateKey(pem: tripleDes, password: "x")) {
            XCTAssertTrue(errorMessage($0).hasPrefix("Nieobsługiwany algorytm szyfrowania klucza: 1.2.840.113549.3.7 (des-ede3-cbc). "), errorMessage($0))
        }
    }

    func testRejectsAnAbsurdPbkdf2IterationCountBeforeDerivingAnything() {
        let pem = encryptedPem(privateKeyInfo: shortScalarKeyInfo, password: "x", declaredIterations: 10_000_001)

        XCTAssertThrowsError(try decryptPrivateKey(pem: pem, password: "x")) {
            XCTAssertEqual(
                errorMessage($0),
                "Nieobsługiwana liczba iteracji PBKDF2 klucza: 10000001 (największa obsługiwana: 10000000)."
            )
        }
    }
}
