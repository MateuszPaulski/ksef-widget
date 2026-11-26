import Foundation

/// Checks the pair first, so a wrong password, a mismatch or an unsupported algorithm leaves nothing behind.
public func installCredentials(certificate: URL, key: URL, password: String, paths: AppPaths, secrets: SecretStore) throws {
    _ = try loadCredentials(certificateURL: certificate, keyURL: key, password: password)
    try writePrivately(Data(contentsOf: certificate), to: paths.certificate)
    try writePrivately(Data(contentsOf: key), to: paths.key)
    try secrets.saveKeyPassword(password)
}
