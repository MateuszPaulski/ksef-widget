import CryptoKit
import Foundation
import Security
import libxml2
@testable import KsefCore

struct XadesCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private let namespaces = [
    ("ds", "http://www.w3.org/2000/09/xmldsig#"),
    ("xades", "http://uri.etsi.org/01903/v1.3.2#"),
]

private func subtree(_ element: String) -> String {
    "(//\(element)/descendant-or-self::node() | //\(element)//@* | //\(element)//namespace::*)"
}

/// Recomputes both digests and verifies SignatureValue with libxml2's exclusive canonicalization,
/// independent of the signer's by-construction strings. Throws on any mismatch.
func checkXades(_ signedXml: String, certificate: Certificate) throws {
    let bytes = Array(signedXml.utf8)
    guard let document = xmlReadMemory(bytes.map { CChar(bitPattern: $0) }, Int32(bytes.count), "signed.xml", nil, Int32(XML_PARSE_NONET.rawValue)),
          let context = xmlXPathNewContext(document)
    else { throw XadesCheckFailure(description: "not well-formed XML") }
    defer {
        xmlXPathFreeContext(context)
        xmlFreeDoc(document)
    }
    for (prefix, uri) in namespaces { xmlXPathRegisterNs(context, prefix, uri) }

    func canonical(_ expression: String) throws -> Data {
        guard let result = xmlXPathEvalExpression(expression, context) else { throw XadesCheckFailure(description: "XPath failed: \(expression)") }
        defer { xmlXPathFreeObject(result) }
        var output: UnsafeMutablePointer<xmlChar>?
        let length = xmlC14NDocDumpMemory(document, result.pointee.nodesetval, Int32(XML_C14N_EXCLUSIVE_1_0.rawValue), nil, 0, &output)
        guard length >= 0, let output else { throw XadesCheckFailure(description: "canonicalization failed: \(expression)") }
        defer { free(output) }  // xmlFree is a shared mutable global, which Swift 6 rejects; libxml2 allocates with malloc
        return Data(bytes: output, count: Int(length))
    }

    func string(_ expression: String) throws -> String {
        guard let result = xmlXPathEvalExpression("string(\(expression))", context), let value = result.pointee.stringval else {
            throw XadesCheckFailure(description: "XPath failed: \(expression)")
        }
        defer { xmlXPathFreeObject(result) }
        return String(cString: value)
    }

    let rootDigest = try string("//ds:Reference[@URI='']/ds:DigestValue")
    let propertiesDigest = try string("//ds:Reference[@URI='#SignedProperties']/ds:DigestValue")
    let root = try canonical("(/descendant-or-self::node() | //@* | //namespace::*)[not(ancestor-or-self::ds:Signature)]")
    let properties = try canonical(subtree("xades:SignedProperties"))
    let signedInfo = try canonical(subtree("ds:SignedInfo"))

    guard Data(SHA256.hash(data: root)).base64EncodedString() == rootDigest else {
        throw XadesCheckFailure(description: "enveloped root digest mismatch")
    }
    guard Data(SHA256.hash(data: properties)).base64EncodedString() == propertiesDigest else {
        throw XadesCheckFailure(description: "SignedProperties digest mismatch")
    }

    let method = try string("//ds:SignatureMethod/@Algorithm")
    guard let signature = Data(base64Encoded: try string("//ds:SignatureValue")) else {
        throw XadesCheckFailure(description: "SignatureValue is not Base64")
    }
    guard let publicKey = SecKeyCopyExternalRepresentation(certificate.publicKey, nil) as Data? else {
        throw XadesCheckFailure(description: "certificate has no exportable public key")
    }
    let valid: Bool
    if method.hasSuffix("#rsa-sha256") {
        valid = SecKeyVerifySignature(certificate.publicKey, .rsaSignatureMessagePKCS1v15SHA256, signedInfo as CFData, signature as CFData, nil)
    } else if method.hasSuffix("#ecdsa-sha256") {
        valid = try P256.Signing.PublicKey(x963Representation: publicKey).isValidSignature(
            P256.Signing.ECDSASignature(rawRepresentation: signature), for: signedInfo
        )
    } else {
        throw XadesCheckFailure(description: "unexpected SignatureMethod \(method)")
    }
    guard valid else { throw XadesCheckFailure(description: "SignatureValue does not verify") }
}
