import Foundation

private let identityFileName = "identity.json"

private struct FolderIdentity: Decodable {
    let nip: String
    let environment: String
}

private func identityURL(_ dataDir: URL) -> URL { dataDir.appendingPathComponent(identityFileName) }

/// The checkpoint and the index carry no identity, so a folder reused for another NIP or environment would resume
/// from the wrong checkpoint without a word. Returns whether a marker exists; a folder without one passes.
func checkDataFolder(_ dataDir: URL, settings: Settings) throws -> Bool {
    guard let data = try readIfExists(identityURL(dataDir)) else { return false }
    guard let identity = try? JSONDecoder().decode(FolderIdentity.self, from: data) else {
        throw KsefError("Uszkodzony plik \(identityFileName)")
    }
    guard identity.nip == settings.nip, identity.environment == settings.environment.rawValue else {
        throw KsefError(
            "Folder faktur zawiera dane innego podatnika lub środowiska (NIP \(identity.nip), \(identity.environment)). "
                + "Wybierz inny folder w Ustawieniach."
        )
    }
    return true
}

func writeDataFolderMarker(_ dataDir: URL, settings: Settings) throws {
    let json = JSONValue.object([
        ("nip", .string(settings.nip)), ("environment", .string(settings.environment.rawValue)),
    ]).compact() + "\n"
    try writeAtomic(Data(json.utf8), to: identityURL(dataDir))
}

/// Claims the folder for the settings' NIP and environment, or throws when it belongs to another.
public func adoptDataFolder(_ settings: Settings) throws {
    let dataDir = URL(fileURLWithPath: settings.dataDir)
    if try !checkDataFolder(dataDir, settings: settings) { try writeDataFolderMarker(dataDir, settings: settings) }
}
