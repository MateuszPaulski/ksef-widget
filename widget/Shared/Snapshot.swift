import Foundation

enum SnapshotFile {
    static let relativePath = "Library/Application Support/ksef-daily-fetch/widget.json"

    // Inside the App Sandbox NSHomeDirectory() and homeDirectoryForCurrentUser return the container,
    // so the real home comes from the password database.
    static var url: URL {
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        return URL(fileURLWithPath: home).appendingPathComponent(relativePath)
    }
}
