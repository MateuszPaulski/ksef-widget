import Foundation

public struct AppPaths: Sendable {
    public let appFolder: URL
    public let settings: URL
    public let certificate: URL
    public let key: URL
    public let snapshot: URL
    public let defaultDataDir: URL
    public let legacyLaunchAgent: URL

    public init(home: URL) {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        appFolder = support.appendingPathComponent("local.ksef-daily-fetch.KsefWidget", isDirectory: true)
        settings = appFolder.appendingPathComponent("settings.json")
        certificate = appFolder.appendingPathComponent("ksef-auth.crt")
        key = appFolder.appendingPathComponent("ksef-auth.key")
        snapshot = support.appendingPathComponent("ksef-daily-fetch/widget.json")
        defaultDataDir = home.appendingPathComponent("Documents/KSeF", isDirectory: true)
        legacyLaunchAgent = home.appendingPathComponent("Library/LaunchAgents/local.ksef-daily-fetch.plist")
    }

    /// The app is not sandboxed, so this is the real home folder.
    public static var current: AppPaths { AppPaths(home: FileManager.default.homeDirectoryForCurrentUser) }
}

/// Folder 0700, file 0600 from the first byte: the temp file is created private and renamed over the old one.
func writePrivately(_ data: Data, to url: URL) throws {
    let folder = url.deletingLastPathComponent()
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let temporary = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
    guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw KsefError("Nie można zapisać pliku \(url.lastPathComponent)")
    }
    guard rename(temporary.path, url.path) == 0 else {
        try? fileManager.removeItem(at: temporary)
        throw KsefError("Nie można zapisać pliku \(url.lastPathComponent)")
    }
}
