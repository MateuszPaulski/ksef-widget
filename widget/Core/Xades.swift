import CryptoKit
import Foundation
import Security

private let ds = "http://www.w3.org/2000/09/xmldsig#"
private let exclusiveC14n = "http://www.w3.org/2001/10/xml-exc-c14n#"
private let enveloped = "\(ds)enveloped-signature"
private let sha256Method = "http://www.w3.org/2001/04/xmlenc#sha256"
private let signedPropertiesType = "http://uri.etsi.org/01903#SignedProperties"
private let xades = "http://uri.etsi.org/01903/v1.3.2#"

func buildAuthTokenRequest(challenge: String, nip: String) -> String {
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\(authTokenRequestStart(challenge: challenge, nip: nip))</AuthTokenRequest>"
}

private func authTokenRequestStart(challenge: String, nip: String) -> String {
    "<AuthTokenRequest xmlns=\"http://ksef.mf.gov.pl/auth/token/2.0\"><Challenge>\(challenge)</Challenge>"
        + "<ContextIdentifier><Nip>\(nip)</Nip></ContextIdentifier><SubjectIdentifierType>certificateSubject</SubjectIdentifierType>"
}

private func base64(_ data: some Sequence<UInt8>) -> String { Data(data).base64EncodedString() }

private func digest(_ text: String) -> String { base64(SHA256.hash(data: Data(text.utf8))) }

// Empty elements are `<x a/>` in the document and `<x a></x>` in canonical form.
private func empty(_ name: String, algorithm: String, canonical: Bool, namespace: String = "") -> String {
    canonical
        ? "<ds:\(name)\(namespace) Algorithm=\"\(algorithm)\"></ds:\(name)>"
        : "<ds:\(name) Algorithm=\"\(algorithm)\"/>"
}

private func signedProperties(canonical: Bool, time: String, certDigest: String, issuer: String, serial: String) -> String {
    let namespace = canonical ? " xmlns:ds=\"\(ds)\"" : ""
    return (canonical ? "<xades:SignedProperties xmlns:xades=\"\(xades)\" Id=\"SignedProperties\">" : "<xades:SignedProperties Id=\"SignedProperties\">")
        + "<xades:SignedSignatureProperties><xades:SigningTime>\(time)</xades:SigningTime>"
        + "<xades:SigningCertificate><xades:Cert><xades:CertDigest>"
        + empty("DigestMethod", algorithm: sha256Method, canonical: canonical, namespace: namespace)
        + "<ds:DigestValue\(namespace)>\(certDigest)</ds:DigestValue></xades:CertDigest>"
        + "<xades:IssuerSerial><ds:X509IssuerName\(namespace)>\(issuer)</ds:X509IssuerName>"
        + "<ds:X509SerialNumber\(namespace)>\(serial)</ds:X509SerialNumber></xades:IssuerSerial>"
        + "</xades:Cert></xades:SigningCertificate></xades:SignedSignatureProperties></xades:SignedProperties>"
}

private func signedInfo(canonical: Bool, method: String, rootDigest: String, propertiesDigest: String) -> String {
    let transform = { (algorithm: String) in empty("Transform", algorithm: algorithm, canonical: canonical) }
    return (canonical ? "<ds:SignedInfo xmlns:ds=\"\(ds)\">" : "<ds:SignedInfo>")
        + empty("CanonicalizationMethod", algorithm: exclusiveC14n, canonical: canonical)
        + empty("SignatureMethod", algorithm: method, canonical: canonical)
        + "<ds:Reference URI=\"\"><ds:Transforms>\(transform(enveloped))\(transform(exclusiveC14n))</ds:Transforms>"
        + empty("DigestMethod", algorithm: sha256Method, canonical: canonical)
        + "<ds:DigestValue>\(rootDigest)</ds:DigestValue></ds:Reference>"
        + (canonical
            ? "<ds:Reference Type=\"\(signedPropertiesType)\" URI=\"#SignedProperties\">"
            : "<ds:Reference URI=\"#SignedProperties\" Type=\"\(signedPropertiesType)\">")
        + "<ds:Transforms>\(transform(exclusiveC14n))</ds:Transforms>"
        + empty("DigestMethod", algorithm: sha256Method, canonical: canonical)
        + "<ds:DigestValue>\(propertiesDigest)</ds:DigestValue></ds:Reference></ds:SignedInfo>"
}

private func escapeIssuer(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private func isValidChallenge(_ challenge: String) -> Bool {
    (1...64).contains(challenge.utf8.count)
        && challenge.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 }
}

// Canonical forms are written out directly, not computed: the document is fixed, every interpolated
// value is validated or escaped, and the tests canonicalize the output with libxml2 as a cross-check.
func signXades(challenge: String, nip: String, credentials: Credentials, signingTime: Date) throws -> String {
    guard isValidChallenge(challenge) else { throw KsefError("Nieoczekiwany format wyzwania KSeF") }
    let certificate = credentials.certificate
    let time = KsefTime.iso(signingTime.addingTimeInterval(-60))
    let certDigest = base64(SHA256.hash(data: certificate.der))
    let issuer = escapeIssuer(certificate.issuerName)

    let root = authTokenRequestStart(challenge: challenge, nip: nip)
    let rootDigest = digest(root + "</AuthTokenRequest>")
    let propertiesDigest = digest(signedProperties(
        canonical: true, time: time, certDigest: certDigest, issuer: issuer, serial: certificate.serialNumber
    ))

    let method: String
    switch credentials.key {
    case .rsa: method = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
    case .ec: method = "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256"
    }
    let canonicalInfo = Data(signedInfo(canonical: true, method: method, rootDigest: rootDigest, propertiesDigest: propertiesDigest).utf8)

    let signature: Data
    switch credentials.key {
    case .rsa(let key):
        var error: Unmanaged<CFError>?
        guard let signed = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, canonicalInfo as CFData, &error) else {
            throw KsefError("Nie udało się podpisać żądania: \(error?.takeRetainedValue().localizedDescription ?? "nieznany błąd")")
        }
        signature = signed as Data
    case .ec(let key):
        signature = try key.signature(for: canonicalInfo).rawRepresentation
    }

    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>" + root
        + "<ds:Signature Id=\"Signature\" xmlns:ds=\"\(ds)\">"
        + signedInfo(canonical: false, method: method, rootDigest: rootDigest, propertiesDigest: propertiesDigest)
        + "<ds:SignatureValue>\(base64(signature))</ds:SignatureValue>"
        + "<ds:KeyInfo><ds:X509Data><ds:X509Certificate>\(base64(certificate.der))</ds:X509Certificate></ds:X509Data></ds:KeyInfo>"
        + "<ds:Object><xades:QualifyingProperties xmlns:xades=\"\(xades)\" Target=\"#Signature\">"
        + signedProperties(canonical: false, time: time, certDigest: certDigest, issuer: issuer, serial: certificate.serialNumber)
        + "</xades:QualifyingProperties></ds:Object></ds:Signature></AuthTokenRequest>"
}
