import CryptoKit
import Foundation
import Security

struct KsefError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension KsefError {
    init(_ message: String) { self.init(message: message) }
}

public func errorMessage(_ error: Error) -> String {
    error.localizedDescription
}

struct Credentials: Sendable {
    let certificate: Certificate
    let key: SigningKey
}

private func publicKeyBytes(of key: SigningKey) -> Data? {
    switch key {
    case .rsa(let privateKey):
        SecKeyCopyPublicKey(privateKey).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
    case .ec(let privateKey):
        privateKey.publicKey.x963Representation
    }
}

func loadCredentials(certificateURL: URL, keyURL: URL, password: String) throws -> Credentials {
    let certificatePem = try String(contentsOf: certificateURL, encoding: .utf8)
    let keyPem = try String(contentsOf: keyURL, encoding: .utf8)
    let key = try decryptPrivateKey(pem: keyPem, password: password)
    let certificate = try Certificate(pem: certificatePem)
    let certificateKey = SecKeyCopyExternalRepresentation(certificate.publicKey, nil) as Data?
    guard certificateKey != nil, certificateKey == publicKeyBytes(of: key) else {
        throw KsefError("Klucz prywatny nie pasuje do certyfikatu")
    }
    return Credentials(certificate: certificate, key: key)
}
