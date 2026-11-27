import Security
import XCTest
@testable import KsefCore

final class CertificateTests: XCTestCase {
    func testIssuerAndSerialMatchNode() throws {
        for name in XadesVector.names {
            let vector = try XadesVector.load(name)
            let certificate = try Certificate(pem: vector.certificatePem)
            XCTAssertEqual(certificate.issuerName, vector.issuer, name)
            XCTAssertEqual(certificate.serialNumber, vector.serial, name)
        }
    }

    func testDerAndPublicKey() throws {
        let vector = try XadesVector.load("xades-rsa")
        let certificate = try Certificate(pem: vector.certificatePem)
        XCTAssertEqual(certificate.der, Data(try XCTUnwrap(pemBody(vector.certificatePem, label: "CERTIFICATE"))))
        XCTAssertNotNil(SecKeyCopyExternalRepresentation(certificate.publicKey, nil))
    }

    func testRejectsNonCertificate() {
        XCTAssertThrowsError(try Certificate(pem: "x")) {
            XCTAssertEqual(
                $0 as? KsefError,
                KsefError(message: "Nie można odczytać certyfikatu: oczekiwano -----BEGIN CERTIFICATE-----")
            )
        }
    }
}
