import CommonCrypto
import Foundation

func der(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
    let length: [UInt8] = body.count < 0x80
        ? [UInt8(body.count)]
        : body.count < 0x100 ? [0x81, UInt8(body.count)] : [0x82, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]
    return [tag] + length + body
}

func derOID(_ dotted: String) -> [UInt8] {
    let arcs = dotted.split(separator: ".").map { UInt64($0)! }
    var body: [UInt8] = []
    for arc in [arcs[0] * 40 + arcs[1]] + arcs.dropFirst(2) {
        var groups = [UInt8(arc & 0x7F)]
        var rest = arc >> 7
        while rest > 0 {
            groups.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        body += groups.reversed()
    }
    return der(0x06, body)
}

enum TestPrf: CaseIterable {
    case implicitSha1, sha1, sha224, sha256, sha384, sha512

    var oid: String? {
        switch self {
        case .implicitSha1: nil
        case .sha1: "1.2.840.113549.2.7"
        case .sha224: "1.2.840.113549.2.8"
        case .sha256: "1.2.840.113549.2.9"
        case .sha384: "1.2.840.113549.2.10"
        case .sha512: "1.2.840.113549.2.11"
        }
    }

    var algorithm: CCPseudoRandomAlgorithm {
        switch self {
        case .implicitSha1, .sha1: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case .sha224: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA224)
        case .sha256: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        case .sha384: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case .sha512: CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        }
    }
}

/// Builds `-----BEGIN ENCRYPTED PRIVATE KEY-----` text for key shapes no installed tool produces.
func encryptedPem(
    privateKeyInfo: [UInt8],
    password: String,
    prf: TestPrf = .sha256,
    keySize: Int = 32,
    declareKeyLength: Bool = false,
    kdfOID: String = "1.2.840.113549.1.5.12",
    cipherOID: String? = nil
) -> String {
    let salt = [UInt8](repeating: 0x5A, count: 16)
    let iv = [UInt8](repeating: 0xA5, count: 16)
    let iterations: UInt32 = 1000

    var derived = [UInt8](repeating: 0, count: keySize)
    _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count, prf.algorithm, iterations, &derived, derived.count)
    var ciphertext = [UInt8](repeating: 0, count: privateKeyInfo.count + kCCBlockSizeAES128)
    var produced = 0
    _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), derived, keySize, iv, privateKeyInfo, privateKeyInfo.count, &ciphertext, ciphertext.count, &produced)

    var kdfParameters = der(0x04, salt) + der(0x02, [UInt8(iterations >> 8), UInt8(iterations & 0xFF)])
    if declareKeyLength { kdfParameters += der(0x02, [UInt8(keySize)]) }
    if let prfOID = prf.oid { kdfParameters += der(0x30, derOID(prfOID) + [0x05, 0x00]) }
    let aesOIDs = [16: "2.16.840.1.101.3.4.1.2", 24: "2.16.840.1.101.3.4.1.22", 32: "2.16.840.1.101.3.4.1.42"]
    let structure = der(0x30, der(0x30,
        derOID("1.2.840.113549.1.5.13") + der(0x30,
            der(0x30, derOID(kdfOID) + der(0x30, kdfParameters))
                + der(0x30, derOID(cipherOID ?? aesOIDs[keySize]!) + der(0x04, iv))
        )
    ) + der(0x04, Array(ciphertext[..<produced])))

    let lines = Data(structure).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return "-----BEGIN ENCRYPTED PRIVATE KEY-----\n\(lines)\n-----END ENCRYPTED PRIVATE KEY-----\n"
}
