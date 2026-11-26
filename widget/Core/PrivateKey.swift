import CommonCrypto
import CryptoKit
import Foundation
import Security

// @unchecked: SecKey is an immutable CF object that Security documents as thread-safe.
enum SigningKey: @unchecked Sendable {
    case rsa(SecKey)
    case ec(P256.Signing.PrivateKey)
}

private enum OID {
    static let pbes2 = "1.2.840.113549.1.5.13"
    static let pbkdf2 = "1.2.840.113549.1.5.12"
    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let prime256v1 = "1.2.840.10045.3.1.7"
}

private let defaultPRF = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)

private let prfByOID: [String: CCPseudoRandomAlgorithm] = [
    "1.2.840.113549.2.7": defaultPRF,
    "1.2.840.113549.2.8": CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA224),
    "1.2.840.113549.2.9": CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
    "1.2.840.113549.2.10": CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384),
    "1.2.840.113549.2.11": CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
]

private let keySizeByCipherOID: [String: Int] = [
    "2.16.840.1.101.3.4.1.2": 16,
    "2.16.840.1.101.3.4.1.22": 24,
    "2.16.840.1.101.3.4.1.42": 32,
]

private let algorithmNames: [String: String] = [
    "1.2.840.113549.1.5.1": "pbeWithMD2AndDES-CBC",
    "1.2.840.113549.1.5.3": "pbeWithMD5AndDES-CBC",
    "1.2.840.113549.1.5.10": "pbeWithSHA1AndDES-CBC",
    "1.2.840.113549.1.12.1.1": "pbeWithSHAAnd128BitRC4",
    "1.2.840.113549.1.12.1.2": "pbeWithSHAAnd40BitRC4",
    "1.2.840.113549.1.12.1.3": "pbeWithSHAAnd3-KeyTripleDES-CBC",
    "1.2.840.113549.1.12.1.4": "pbeWithSHAAnd2-KeyTripleDES-CBC",
    "1.2.840.113549.1.12.1.5": "pbeWithSHAAnd128BitRC2-CBC",
    "1.2.840.113549.1.12.1.6": "pbeWithSHAAnd40BitRC2-CBC",
    "1.3.6.1.4.1.11591.4.11": "scrypt",
    "1.2.840.113549.3.7": "des-ede3-cbc",
    "1.2.840.113549.3.2": "rc2-cbc",
    "1.3.14.3.2.7": "des-cbc",
    "1.2.840.113549.2.12": "hmacWithSHA512-224",
    "1.2.840.113549.2.13": "hmacWithSHA512-256",
]

private let decryptionFailed = "odszyfrowanie nie powiodło się"

private func unreadable(_ reason: String) -> KsefError {
    KsefError("Nie można odczytać klucza prywatnego (złe hasło lub format): \(reason)")
}

private func unsupportedAlgorithm(_ oid: String) -> KsefError {
    KsefError(
        "Nieobsługiwany algorytm szyfrowania klucza: \(oid) (\(algorithmNames[oid] ?? "nieznany")). "
            + "Obsługiwane: PBES2 z PBKDF2 (HMAC-SHA1, SHA224, SHA256, SHA384, SHA512) i AES-128/192/256-CBC."
    )
}

private func unsupportedType(_ type: String) -> KsefError {
    KsefError("Nieobsługiwany typ klucza: \(type); wymagany RSA 2048+ lub EC P-256")
}

private struct EncryptedKey {
    let salt: [UInt8]
    let iterations: UInt32
    let prf: CCPseudoRandomAlgorithm
    let keySize: Int
    let iv: [UInt8]
    let ciphertext: [UInt8]
}

private func algorithm(_ element: DERElement) throws -> (oid: String, parameters: DERElement?) {
    guard element.tag == 0x30 else { throw DERError() }
    let parts = try element.children()
    guard let oid = parts.first, oid.tag == 0x06 else { throw DERError() }
    return (oidString(oid.body), parts.count > 1 ? parts[1] : nil)
}

private func unsignedInteger(_ element: DERElement) throws -> UInt32 {
    guard element.tag == 0x02, element.body.count <= 5, element.body.first.map({ $0 < 0x80 }) ?? false else { throw DERError() }
    guard let value = UInt32(exactly: element.body.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }), value > 0 else { throw DERError() }
    return value
}

// Checks OIDs in structure order (outer, KDF, PRF, cipher) so the first unsupported one is the one named.
private func parseEncryptedKey(_ der: [UInt8]) throws -> EncryptedKey {
    var reader = DERReader(der)
    let top = try reader.next()
    let parts = try top.children()
    guard top.tag == 0x30, parts.count == 2, parts[1].tag == 0x04 else { throw DERError() }

    let outer = try algorithm(parts[0])
    guard outer.oid == OID.pbes2 else { throw unsupportedAlgorithm(outer.oid) }
    guard let pbes2 = outer.parameters, pbes2.tag == 0x30 else { throw DERError() }
    let schemes = try pbes2.children()
    guard schemes.count == 2 else { throw DERError() }

    let kdf = try algorithm(schemes[0])
    guard kdf.oid == OID.pbkdf2 else { throw unsupportedAlgorithm(kdf.oid) }
    guard let kdfParameters = kdf.parameters, kdfParameters.tag == 0x30 else { throw DERError() }
    var fields = try kdfParameters.children()[...]
    guard let salt = fields.popFirst(), salt.tag == 0x04, let iterations = fields.popFirst() else { throw DERError() }
    // keyLength (INTEGER) and prf (SEQUENCE) are both optional, so tell them apart by tag.
    var declaredKeySize: UInt32?
    if fields.first?.tag == 0x02 { declaredKeySize = try unsignedInteger(fields.removeFirst()) }
    var prf = defaultPRF
    if fields.first?.tag == 0x30 {
        let oid = try algorithm(fields.removeFirst()).oid
        guard let known = prfByOID[oid] else { throw unsupportedAlgorithm(oid) }
        prf = known
    }
    guard fields.isEmpty else { throw DERError() }

    let cipher = try algorithm(schemes[1])
    guard let keySize = keySizeByCipherOID[cipher.oid] else { throw unsupportedAlgorithm(cipher.oid) }
    guard declaredKeySize.map({ Int($0) == keySize }) ?? true else { throw DERError() }
    guard let iv = cipher.parameters, iv.tag == 0x04, iv.body.count == kCCBlockSizeAES128 else { throw DERError() }

    return EncryptedKey(
        salt: salt.body,
        iterations: try unsignedInteger(iterations),
        prf: prf,
        keySize: keySize,
        iv: iv.body,
        ciphertext: parts[1].body
    )
}

private func wipe(_ bytes: inout [UInt8]) {
    guard !bytes.isEmpty else { return }
    bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
}

private func decrypt(_ key: EncryptedKey, password: String) throws -> [UInt8] {
    var derived = [UInt8](repeating: 0, count: key.keySize)
    defer { wipe(&derived) }
    let derivation = password.withCString { passwordPointer in
        key.salt.withUnsafeBufferPointer { salt in
            derived.withUnsafeMutableBufferPointer { output in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passwordPointer, password.utf8.count,
                    salt.baseAddress, salt.count, key.prf, key.iterations, output.baseAddress, output.count
                )
            }
        }
    }
    guard derivation == kCCSuccess else { throw unreadable(decryptionFailed) }

    var output = [UInt8](repeating: 0, count: key.ciphertext.count + kCCBlockSizeAES128)
    defer { wipe(&output) }
    var produced = 0
    let status = CCCrypt(
        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
        derived, derived.count, key.iv, key.ciphertext, key.ciphertext.count, &output, output.count, &produced
    )
    guard status == kCCSuccess else { throw unreadable(decryptionFailed) }
    return Array(output[..<produced])
}

private func signingKey(fromPrivateKeyInfo plain: [UInt8]) throws -> SigningKey {
    let algorithmIdentifier: (oid: String, parameters: DERElement?)
    let privateKey: [UInt8]
    do {
        var reader = DERReader(plain)
        let info = try reader.next()
        let parts = try info.children()
        guard info.tag == 0x30, parts.count >= 3, parts[0].tag == 0x02, parts[2].tag == 0x04 else { throw DERError() }
        algorithmIdentifier = try algorithm(parts[1])
        privateKey = parts[2].body
    } catch is DERError {
        throw unreadable(decryptionFailed)
    }

    switch algorithmIdentifier.oid {
    case OID.rsaEncryption:
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(Data(privateKey) as CFData, attributes as CFDictionary, nil) else {
            throw unreadable(decryptionFailed)
        }
        let bits = (SecKeyCopyAttributes(key) as? [CFString: Any])?[kSecAttrKeySizeInBits] as? Int ?? 0
        guard bits >= 2048 else { throw unsupportedType("rsa") }
        return .rsa(key)
    case OID.ecPublicKey:
        guard let curve = algorithmIdentifier.parameters, curve.tag == 0x06, oidString(curve.body) == OID.prime256v1 else {
            throw unsupportedType("ec")
        }
        guard let key = try? P256.Signing.PrivateKey(derRepresentation: plain) else { throw unreadable(decryptionFailed) }
        return .ec(key)
    default:
        throw unsupportedType(algorithmIdentifier.oid)
    }
}

func decryptPrivateKey(pem: String, password: String) throws -> SigningKey {
    guard let der = pemBody(pem, label: "ENCRYPTED PRIVATE KEY") else {
        throw unreadable("oczekiwano -----BEGIN ENCRYPTED PRIVATE KEY-----")
    }
    let encrypted: EncryptedKey
    do {
        encrypted = try parseEncryptedKey(der)
    } catch is DERError {
        throw unreadable("uszkodzona struktura PKCS#8")
    }
    var plain = try decrypt(encrypted, password: password)
    defer { wipe(&plain) }
    return try signingKey(fromPrivateKeyInfo: plain)
}
