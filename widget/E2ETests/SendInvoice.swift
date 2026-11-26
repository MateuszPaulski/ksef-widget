// Test-only online-session sender: puts an invoice into the KSeF TEST environment so the fetch path can be verified.
// The invoice template is adapted from invoice-template-fa-3-with-custom-Subject2.xml in
// https://github.com/CIRFMF/ksef-client-csharp (MIT, (c) 2025 Ministerstwo Finansów).
import CommonCrypto
import CryptoKit
import Foundation
import Security
@testable import KsefCore

private let pollIntervalMs = 2000
private let maxPolls = 90
private let invoiceRejectedFrom = 400

private struct PublicKeyCertificate: Decodable {
    let certificate: String
    let publicKeyId: String
    let validFrom: String
    let validTo: String
    let usage: [String]
}

private struct OnlineSession: Decodable {
    let referenceNumber: String
}

private struct InvoiceStatus: Decodable {
    struct Status: Decodable {
        let code: Int
        let description: String
        let details: [String]?
    }
    let ksefNumber: String?
    let permanentStorageDate: String?
    let status: Status
}

private func sha256Base64(_ data: Data) -> String {
    Data(SHA256.hash(data: data)).base64EncodedString()
}

private func randomBytes(_ count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw KsefError("SecRandomCopyBytes failed") }
    return Data(bytes)
}

private func aes256CbcEncrypt(_ plain: Data, key: Data, iv: Data) throws -> Data {
    var output = Data(count: plain.count + kCCBlockSizeAES128)
    var written = 0
    let capacity = output.count
    let status = output.withUnsafeMutableBytes { out in
        plain.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                        input.baseAddress, plain.count, out.baseAddress, capacity, &written
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else { throw KsefError("CCCrypt failed with \(status)") }
    return output.prefix(written)
}

private func symmetricKeyCertificatePublicKey(_ certificates: [PublicKeyCertificate]) throws -> (key: SecKey, id: String) {
    let now = KsefTime.millis(Date())
    let valid = certificates.first { candidate in
        guard candidate.usage.contains("SymmetricKeyEncryption"),
              let from = KsefTime.millis(candidate.validFrom), let to = KsefTime.millis(candidate.validTo)
        else { return false }
        return from <= now && now <= to
    }
    guard let valid else {
        let offered = certificates.map { "\($0.usage) \($0.validFrom)..\($0.validTo)" }.joined(separator: "; ")
        throw KsefError("KSeF TEST did not offer a valid SymmetricKeyEncryption certificate: \(offered)")
    }
    guard let der = Data(base64Encoded: valid.certificate), let certificate = SecCertificateCreateWithData(nil, der as CFData),
          let key = SecCertificateCopyKey(certificate)
    else { throw KsefError("KSeF TEST sent a certificate that cannot be read") }
    return (key, valid.publicKeyId)
}

func sendTestInvoice(
    http: KsefHTTP, accessToken: String, xml: Data, sleep: @Sendable (Int) async -> Void
) async throws -> (ksefNumber: String, permanentStorageDate: String) {
    let certificates = try decodeKsef(
        [PublicKeyCertificate].self, from: try await http.send("GET", "/security/public-key-certificates"),
        endpoint: "GET /security/public-key-certificates"
    )
    let (publicKey, publicKeyId) = try symmetricKeyCertificatePublicKey(certificates)

    let key = try randomBytes(32)
    let iv = try randomBytes(16)
    var encryptionError: Unmanaged<CFError>?
    guard let encryptedKey = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionOAEPSHA256, key as CFData, &encryptionError) as Data? else {
        throw KsefError("Could not encrypt the symmetric key: \(encryptionError?.takeRetainedValue().localizedDescription ?? "unknown error")")
    }

    let session = try decodeKsef(
        OnlineSession.self,
        from: try await http.send("POST", "/sessions/online", token: accessToken, json: .object([
            ("formCode", .object([("systemCode", .string("FA (3)")), ("schemaVersion", .string("1-0E")), ("value", .string("FA"))])),
            ("encryption", .object([
                ("encryptedSymmetricKey", .string(encryptedKey.base64EncodedString())),
                ("initializationVector", .string(iv.base64EncodedString())),
                ("publicKeyId", .string(publicKeyId)),
            ])),
        ])),
        endpoint: "POST /sessions/online"
    )

    let encrypted = try aes256CbcEncrypt(xml, key: key, iv: iv)
    let sent = try decodeKsef(
        OnlineSession.self,
        from: try await http.send("POST", "/sessions/online/\(session.referenceNumber)/invoices", token: accessToken, json: .object([
            ("invoiceHash", .string(sha256Base64(xml))),
            ("invoiceSize", .number(Double(xml.count))),
            ("encryptedInvoiceHash", .string(sha256Base64(encrypted))),
            ("encryptedInvoiceSize", .number(Double(encrypted.count))),
            ("encryptedInvoiceContent", .string(encrypted.base64EncodedString())),
        ])),
        endpoint: "POST /sessions/online/{referenceNumber}/invoices"
    )

    for poll in 0..<maxPolls {
        if poll > 0 { await sleep(pollIntervalMs) }
        let invoice = try decodeKsef(
            InvoiceStatus.self,
            from: try await http.send("GET", "/sessions/\(session.referenceNumber)/invoices/\(sent.referenceNumber)", token: accessToken),
            endpoint: "GET /sessions/{referenceNumber}/invoices/{invoiceReferenceNumber}"
        )
        let status = invoice.status
        if status.code >= invoiceRejectedFrom {
            let details = status.details.flatMap { $0.isEmpty ? nil : " — " + $0.joined(separator: ", ") } ?? ""
            throw KsefError("KSeF TEST rejected the invoice (\(status.code): \(status.description)\(details))")
        }
        if status.code == 200, let ksefNumber = invoice.ksefNumber, !ksefNumber.isEmpty,
           let permanentStorageDate = invoice.permanentStorageDate, !permanentStorageDate.isEmpty {
            _ = try await http.send("POST", "/sessions/online/\(session.referenceNumber)/close", token: accessToken)
            return (ksefNumber, permanentStorageDate)
        }
    }
    throw KsefError("KSeF TEST did not settle the invoice within \(maxPolls * pollIntervalMs / 1000) s")
}
