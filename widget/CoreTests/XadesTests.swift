import CryptoKit
import XCTest
@testable import KsefCore

private let ds = "http://www.w3.org/2000/09/xmldsig#"
private let excC14n = "http://www.w3.org/2001/10/xml-exc-c14n#"
private let sha256 = "http://www.w3.org/2001/04/xmlenc#sha256"
private let enveloped = "\(ds)enveloped-signature"
private let ecdsaSha256 = "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256"
private let rsaSha256 = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
private let challenge = "20261126-CR-0123456789-ABCDEF0123-AB"
private let signingTime = Date(timeIntervalSince1970: 1_795_680_000)  // 2026-11-26T08:00:00Z

private func escapeXml(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func firstMatch(_ text: String, _ pattern: String) throws -> NSTextCheckingResult? {
    let expression = try NSRegularExpression(pattern: pattern)
    return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
}

private func matches(_ text: String, _ pattern: String) throws -> Bool {
    try firstMatch(text, pattern) != nil
}

private func capture(_ text: String, _ pattern: String) throws -> String? {
    guard let match = try firstMatch(text, pattern), let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

private func textOf(_ xml: String, _ name: String) throws -> String? {
    try capture(xml, "<\(name)(?: [^>]*)?>([^<]*)</\(name)>")
}

private func replacingSignatureValue(in xml: String, with other: String) throws -> String {
    let pattern = "(<ds:SignatureValue>)[^<]*(</ds:SignatureValue>)"
    let replacement = try XCTUnwrap(textOf(other, "ds:SignatureValue"))
    return try NSRegularExpression(pattern: pattern).stringByReplacingMatches(
        in: xml, range: NSRange(xml.startIndex..., in: xml), withTemplate: "$1\(replacement)$2"
    )
}

final class XadesTests: XCTestCase {
    private var fresh: [KeyType: Credentials] = [:]
    private let keyTypes: [(KeyType, String)] = [(.rsa, "rsa"), (.ec, "ec")]

    override func setUpWithError() throws {
        let dir = try temporaryDirectory()
        for (keyType, _) in keyTypes {
            let files = try TestCredentials.make(nip: randomNip(), keyType: keyType, in: dir)
            fresh[keyType] = try loadCredentials(certificateURL: files.certificateURL, keyURL: files.keyURL, password: files.password)
        }
    }

    private func fixtureCredentials(_ vector: XadesVector) throws -> Credentials {
        let dir = try temporaryDirectory()
        let certificateURL = dir.appendingPathComponent("certificate.crt")
        let keyURL = dir.appendingPathComponent("key.key")
        try vector.certificatePem.write(to: certificateURL, atomically: true, encoding: .utf8)
        try vector.keyPem.write(to: keyURL, atomically: true, encoding: .utf8)
        return try loadCredentials(certificateURL: certificateURL, keyURL: keyURL, password: vector.password)
    }

    private func sign(_ vector: XadesVector) throws -> String {
        let time = try XCTUnwrap(KsefTime.millis(vector.signingTime))
        return try signXades(
            challenge: vector.challenge, nip: vector.contextNip,
            credentials: fixtureCredentials(vector), signingTime: Date(timeIntervalSince1970: Double(time) / 1000)
        )
    }

    private func signature(_ keyType: KeyType) throws -> (signed: String, signature: String) {
        let signed = try signXades(challenge: challenge, nip: "5265877635", credentials: XCTUnwrap(fresh[keyType]), signingTime: signingTime)
        let start = try XCTUnwrap(signed.range(of: "<ds:Signature"))
        let end = try XCTUnwrap(signed.range(of: "</ds:Signature>"))
        return (signed, String(signed[start.lowerBound..<end.upperBound]))
    }

    func testBuildsTheAuthTokenRequestDocument() {
        XCTAssertEqual(
            buildAuthTokenRequest(challenge: challenge, nip: "5265877635"),
            "<?xml version=\"1.0\" encoding=\"utf-8\"?><AuthTokenRequest xmlns=\"http://ksef.mf.gov.pl/auth/token/2.0\"><Challenge>20261126-CR-0123456789-ABCDEF0123-AB</Challenge><ContextIdentifier><Nip>5265877635</Nip></ContextIdentifier><SubjectIdentifierType>certificateSubject</SubjectIdentifierType></AuthTokenRequest>"
        )
    }

    func testRsaOutputIsByteIdenticalToTypeScript() throws {
        for name in ["xades-rsa", "xades-awkward-issuer"] {
            let vector = try XadesVector.load(name)
            XCTAssertEqual(try sign(vector), vector.signedXml, name)
        }
    }

    func testEcOutputMatchesTypeScriptExceptTheSignature() throws {
        for name in ["xades-ec", "xades-organization-identifier"] {
            let vector = try XadesVector.load(name)
            let swift = try sign(vector)
            XCTAssertEqual(try replacingSignatureValue(in: swift, with: vector.signedXml), vector.signedXml, name)
            let value = try XCTUnwrap(textOf(swift, "ds:SignatureValue"))
            XCTAssertEqual(Data(base64Encoded: value)?.count, 64, name)
            let certificate = try Certificate(pem: vector.certificatePem)
            XCTAssertNoThrow(try checkXades(vector.signedXml, certificate: certificate), "TypeScript output, \(name)")
            XCTAssertNoThrow(try checkXades(swift, certificate: certificate), "Swift output, \(name)")
        }
    }

    func testUsesTheExpectedSignatureAndCanonicalizationMethods() throws {
        for (keyType, name) in keyTypes {
            let (_, signature) = try signature(keyType)
            let method = keyType == .rsa ? rsaSha256 : ecdsaSha256
            XCTAssertTrue(try matches(signature, "<ds:SignatureMethod Algorithm=\"\(method)\""), name)
            XCTAssertTrue(try matches(signature, "<ds:CanonicalizationMethod Algorithm=\"\(excC14n)\""), name)
        }
    }

    func testHasExactlyTheTwoXadesReferences() throws {
        for (keyType, name) in keyTypes {
            let (_, signature) = try signature(keyType)
            XCTAssertEqual(signature.components(separatedBy: "<ds:Reference ").count - 1, 2, name)
            XCTAssertTrue(try matches(
                signature,
                "<ds:Reference URI=\"\"><ds:Transforms><ds:Transform Algorithm=\"\(enveloped)\"\\s*/><ds:Transform Algorithm=\"\(excC14n)\"\\s*/></ds:Transforms><ds:DigestMethod Algorithm=\"\(sha256)\"\\s*/>"
            ), name)
            XCTAssertTrue(try matches(
                signature,
                "<ds:Reference (?:URI=\"#SignedProperties\" Type=\"http://uri.etsi.org/01903#SignedProperties\"|Type=\"http://uri.etsi.org/01903#SignedProperties\" URI=\"#SignedProperties\")><ds:Transforms><ds:Transform Algorithm=\"\(excC14n)\"\\s*/></ds:Transforms><ds:DigestMethod Algorithm=\"\(sha256)\"\\s*/>"
            ), name)
        }
    }

    func testAppendsAnIdSignatureSignatureAsTheLastChildOfTheRoot() throws {
        for (keyType, name) in keyTypes {
            let (signed, signature) = try signature(keyType)
            XCTAssertTrue(try matches(signature, "^<ds:Signature [^>]*Id=\"Signature\""), name)
            XCTAssertTrue(signed.hasSuffix("</ds:Signature></AuthTokenRequest>"), name)
        }
    }

    func testCarriesQualifyingPropertiesTargetingTheSignatureInsideDsObject() throws {
        for (keyType, name) in keyTypes {
            let (_, signature) = try signature(keyType)
            XCTAssertTrue(try matches(signature, "<ds:Object><xades:QualifyingProperties [^>]*xmlns:xades=\"http://uri\\.etsi\\.org/01903/v1\\.3\\.2#\"[^>]*>"), name)
            XCTAssertTrue(try matches(signature, "<xades:QualifyingProperties [^>]*Target=\"#Signature\""), name)
            XCTAssertTrue(try matches(signature, "<xades:SignedProperties Id=\"SignedProperties\">"), name)
        }
    }

    func testSignsOneMinuteBeforeTheGivenTime() throws {
        for (keyType, name) in keyTypes {
            let (_, signature) = try signature(keyType)
            XCTAssertEqual(try textOf(signature, "xades:SigningTime"), "2026-11-26T07:59:00.000Z", name)
        }
    }

    func testDescribesTheSigningCertificate() throws {
        for (keyType, name) in keyTypes {
            let (_, signature) = try signature(keyType)
            let certificate = try XCTUnwrap(fresh[keyType]).certificate
            let digest = try capture(signature, "<xades:CertDigest><ds:DigestMethod Algorithm=\"\(sha256)\"\\s*/><ds:DigestValue>([^<]*)</ds:DigestValue></xades:CertDigest>")
            XCTAssertEqual(digest, Data(SHA256.hash(data: certificate.der)).base64EncodedString(), name)
            XCTAssertEqual(try textOf(signature, "ds:X509SerialNumber"), certificate.serialNumber, name)
            XCTAssertEqual(try textOf(signature, "ds:X509IssuerName"), escapeXml(certificate.issuerName), name)
        }
    }

    func testEmbedsTheCertificateInKeyInfo() throws {
        for (keyType, name) in keyTypes {
            let (_, signature) = try signature(keyType)
            let certificate = try XCTUnwrap(fresh[keyType]).certificate
            XCTAssertEqual(try textOf(signature, "ds:X509Certificate"), certificate.der.base64EncodedString(), name)
        }
    }

    func testWritesSignatureValueAs64RawBytes() throws {
        let (_, signature) = try signature(.ec)
        let value = try XCTUnwrap(textOf(signature, "ds:SignatureValue"))
        XCTAssertEqual(Data(base64Encoded: value)?.count, 64)
    }

    func testVerifiesAgainstItsOwnCertificate() throws {
        for (keyType, name) in keyTypes {
            let (signed, _) = try signature(keyType)
            XCTAssertNoThrow(try checkXades(signed, certificate: XCTUnwrap(fresh[keyType]).certificate), name)
        }
    }

    func testRejectsAnUnexpectedChallenge() throws {
        let rsa = try XCTUnwrap(fresh[.rsa])
        XCTAssertThrowsError(try signXades(challenge: "a<b", nip: "5265877635", credentials: rsa, signingTime: signingTime)) {
            XCTAssertEqual($0 as? KsefError, KsefError(message: "Nieoczekiwany format wyzwania KSeF"))
        }
    }
}
