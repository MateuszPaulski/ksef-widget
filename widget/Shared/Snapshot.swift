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

struct Snapshot: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable { case complete, partial, failed }

    struct Invoice: Decodable, Equatable, Sendable {
        let ksefNumber: String
        let seller: String
        let amount: String
        let issueDate: String
        let viewUrl: String
    }

    let updatedAt: Date
    let status: Status
    let reason: String?
    let today: String
    let savedToday: Int
    let invoices: [Invoice]
}

enum SnapshotLoadError: Error, Equatable, Sendable {
    case missing
    case unreadable(String)
}

extension SnapshotFile {
    static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        // Accepts both Node's `…41.123Z` and `…41Z`.
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            do {
                return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
            } catch {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO 8601 date: \(string)")
                )
            }
        }
        return try decoder.decode(Snapshot.self, from: data)
    }

    static func load(from url: URL = SnapshotFile.url) -> Result<Snapshot, SnapshotLoadError> {
        do {
            return .success(try decode(Data(contentsOf: url)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .failure(.missing)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }
}
