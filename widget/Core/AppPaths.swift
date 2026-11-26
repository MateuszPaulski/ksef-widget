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

/// Folder 0700, file 0600 from the first byte: `open(2)` creates the file with the private mode, so nothing ever
/// sees it with a wider one. An interrupted save may leave `url` behind; it is replaced, anything else refuses.
func stagePrivately(_ data: Data, at url: URL) throws {
    let folder = url.deletingLastPathComponent()
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    unlink(url.path)
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw KsefError("Nie można zapisać pliku \(url.lastPathComponent)") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: data)
        try handle.close()
    } catch {
        try? fileManager.removeItem(at: url)
        throw KsefError("Nie można zapisać pliku \(url.lastPathComponent)")
    }
}

func moveIntoPlace(_ staged: URL, to url: URL) throws {
    guard rename(staged.path, url.path) == 0 else {
        try? FileManager.default.removeItem(at: staged)
        throw KsefError("Nie można zapisać pliku \(url.lastPathComponent)")
    }
}

func writePrivately(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
    try stagePrivately(data, at: temporary)
    try moveIntoPlace(temporary, to: url)
}
