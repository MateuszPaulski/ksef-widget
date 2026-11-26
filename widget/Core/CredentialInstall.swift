import Foundation

/// Validates the pair, stages both files next to their targets, then saves the password and renames them into place.
/// A failure deletes the staged files and leaves the old files and password untouched until the Keychain write.
/// `beforeStaging` runs after validation (nothing is left behind for a bad pair); `beforeKeychain` after both files are staged.
func installCredentials(
    certificate: URL, key: URL, password: String, paths: AppPaths, secrets: SecretStore,
    beforeStaging: () throws -> Void = {}, beforeKeychain: () throws -> Void = {}
) throws {
    let certificateData = try Data(contentsOf: certificate)
    let keyData = try Data(contentsOf: key)
    _ = try loadCredentials(
        certificatePem: String(decoding: certificateData, as: UTF8.self), keyPem: String(decoding: keyData, as: UTF8.self),
        password: password
    )
    try beforeStaging()

    let stagedCertificate = paths.certificate.appendingPathExtension("new")
    let stagedKey = paths.key.appendingPathExtension("new")
    var staged: [URL] = []
    do {
        try stagePrivately(certificateData, at: stagedCertificate)
        staged.append(stagedCertificate)
        try stagePrivately(keyData, at: stagedKey)
        staged.append(stagedKey)
        try beforeKeychain()
        try secrets.saveKeyPassword(password)
        try moveIntoPlace(stagedCertificate, to: paths.certificate)
        try moveIntoPlace(stagedKey, to: paths.key)
    } catch {
        for url in staged { try? FileManager.default.removeItem(at: url) }
        throw error
    }
}
