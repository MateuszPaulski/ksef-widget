import XCTest
@testable import KsefCore

final class CredentialsTests: XCTestCase {
    private var rsa: TestCredentialFiles!
    private var ec: TestCredentialFiles!

    override func setUpWithError() throws {
        let dir = try temporaryDirectory()
        rsa = try TestCredentials.make(nip: randomNip(), keyType: .rsa, in: dir)
        ec = try TestCredentials.make(nip: randomNip(), keyType: .ec, in: dir)
    }

    func testLoadsAnEncryptedRsaKeyAndItsCertificate() throws {
        let credentials = try loadCredentials(certificateURL: rsa.certificateURL, keyURL: rsa.keyURL, password: rsa.password)
        guard case .rsa = credentials.key else { return XCTFail("expected an RSA key") }
        XCTAssertTrue(credentials.certificate.pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
    }

    func testLoadsAnEncryptedEcP256Key() throws {
        let credentials = try loadCredentials(certificateURL: ec.certificateURL, keyURL: ec.keyURL, password: ec.password)
        guard case .ec = credentials.key else { return XCTFail("expected an EC key") }
    }

    func testRejectsAWrongPassword() {
        XCTAssertThrowsError(try loadCredentials(certificateURL: rsa.certificateURL, keyURL: rsa.keyURL, password: "wrong")) {
            XCTAssertTrue(
                errorMessage($0).hasPrefix("Nie można odczytać klucza prywatnego (złe hasło lub format)"),
                errorMessage($0)
            )
        }
    }

    func testRejectsAKeyThatDoesNotMatchTheCertificate() {
        XCTAssertThrowsError(try loadCredentials(certificateURL: rsa.certificateURL, keyURL: ec.keyURL, password: ec.password)) {
            XCTAssertEqual($0 as? KsefError, KsefError(message: "Klucz prywatny nie pasuje do certyfikatu"))
        }
    }

    func testRejectsASmallRsaKey() throws {
        let small = try TestCredentials.make(nip: randomNip(), keyType: .rsa, rsaBits: 1024, in: try temporaryDirectory())
        XCTAssertThrowsError(try loadCredentials(certificateURL: small.certificateURL, keyURL: small.keyURL, password: small.password)) {
            XCTAssertEqual(
                $0 as? KsefError,
                KsefError(message: "Nieobsługiwany typ klucza: rsa; wymagany RSA 2048+ lub EC P-256")
            )
        }
    }
}
