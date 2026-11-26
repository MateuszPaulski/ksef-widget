import Foundation

/// Decoded by hand: a missing `sellerName` key is an error, only an explicit null is allowed.
struct IndexEntry: Decodable, Equatable, Sendable {
    let ksefNumber: String
    let invoiceNumber: String
    let issueDate: String
    let sellerNip: String
    let sellerName: String?
    let grossAmount: Double
    let currency: String
    let permanentStorageDate: String
    let invoiceHash: String
    let file: String
    let savedAt: String
}

extension IndexEntry {
    private enum Keys: String, CodingKey {
        case ksefNumber, invoiceNumber, issueDate, sellerNip, sellerName, grossAmount
        case currency, permanentStorageDate, invoiceHash, file, savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init(
            ksefNumber: try container.decode(String.self, forKey: .ksefNumber),
            invoiceNumber: try container.decode(String.self, forKey: .invoiceNumber),
            issueDate: try container.decode(String.self, forKey: .issueDate),
            sellerNip: try container.decode(String.self, forKey: .sellerNip),
            sellerName: try container.decode(String?.self, forKey: .sellerName),
            grossAmount: try container.decode(Double.self, forKey: .grossAmount),
            currency: try container.decode(String.self, forKey: .currency),
            permanentStorageDate: try container.decode(String.self, forKey: .permanentStorageDate),
            invoiceHash: try container.decode(String.self, forKey: .invoiceHash),
            file: try container.decode(String.self, forKey: .file),
            savedAt: try container.decode(String.self, forKey: .savedAt)
        )
    }

    fileprivate var jsonLine: String {
        JSONValue.object([
            ("ksefNumber", .string(ksefNumber)),
            ("invoiceNumber", .string(invoiceNumber)),
            ("issueDate", .string(issueDate)),
            ("sellerNip", .string(sellerNip)),
            ("sellerName", sellerName.map(JSONValue.string) ?? .null),
            ("grossAmount", .number(grossAmount)),
            ("currency", .string(currency)),
            ("permanentStorageDate", .string(permanentStorageDate)),
            ("invoiceHash", .string(invoiceHash)),
            ("file", .string(file)),
            ("savedAt", .string(savedAt)),
        ]).compact() + "\n"
    }
}

private struct State: Decodable {
    let checkpoint: String
}

private let newline = UInt8(ascii: "\n")

private func readIfExists(_ url: URL) throws -> Data? {
    do {
        return try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return nil
    }
}

func writeAtomic(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func append(_ data: Data, to url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
        try data.write(to: url)
        return
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

func readIndex(dataDir: URL) throws -> [IndexEntry] {
    guard let data = try readIfExists(dataDir.appendingPathComponent("index.jsonl")) else { return [] }
    var entries: [IndexEntry] = []
    // Split on the newline byte only: Character-based line splitting also breaks at an unescaped U+2028 inside a JSON string.
    for (offset, line) in data.split(separator: newline, omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
        guard let entry = try? JSONDecoder().decode(IndexEntry.self, from: Data(line)) else {
            throw KsefError("Uszkodzony plik index.jsonl, linia \(offset + 1)")
        }
        entries.append(entry)
    }
    return entries
}

func appendReport(dataDir: URL, day: String, section: String) throws {
    let directory = dataDir.appendingPathComponent("reports")
    let url = directory.appendingPathComponent("\(day).md")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        // Fails if the file exists, so the header is written only for a new file.
        try Data("# Faktury z KSeF — \(day)\n\n\(section)\n".utf8).write(to: url, options: .withoutOverwriting)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
        try append(Data("\(section)\n".utf8), to: url)
    }
}

/// Used by one run at a time.
final class Store {
    private let dataDir: URL
    private let now: @Sendable () -> Date
    private var saved: Set<String>
    private var savedAtMillis: [Int64]
    private(set) var checkpoint: String?

    private init(dataDir: URL, now: @escaping @Sendable () -> Date, checkpoint: String?, entries: [IndexEntry]) {
        self.dataDir = dataDir
        self.now = now
        self.checkpoint = checkpoint
        saved = Set(entries.map(\.ksefNumber))
        savedAtMillis = entries.compactMap { KsefTime.millis($0.savedAt) }
    }

    static func open(dataDir: URL, now: @escaping @Sendable () -> Date) throws -> Store {
        var checkpoint: String?
        if let state = try readIfExists(dataDir.appendingPathComponent("state.json")) {
            guard let decoded = try? JSONDecoder().decode(State.self, from: state) else {
                throw KsefError("Uszkodzony plik state.json")
            }
            checkpoint = decoded.checkpoint
        }
        return Store(dataDir: dataDir, now: now, checkpoint: checkpoint, entries: try readIndex(dataDir: dataDir))
    }

    func has(_ ksefNumber: String) -> Bool { saved.contains(ksefNumber) }

    func savedSince(_ instant: Date) -> Int {
        let threshold = KsefTime.millis(instant)
        return savedAtMillis.filter { $0 > threshold }.count
    }

    func saveInvoice(_ invoice: InvoiceMetadata, xml: Data) throws {
        let dateParts = invoice.issueDate.split(separator: "-")
        guard dateParts.count >= 2 else { throw KsefError("Nieprawidłowa data wystawienia faktury") }
        let file = "invoices/\(dateParts[0])/\(dateParts[1])/\(invoice.ksefNumber).xml"
        try writeAtomic(xml, to: dataDir.appendingPathComponent(file))
        let savedAt = now()
        let entry = IndexEntry(
            ksefNumber: invoice.ksefNumber, invoiceNumber: invoice.invoiceNumber, issueDate: invoice.issueDate,
            sellerNip: invoice.seller.nip, sellerName: invoice.seller.name, grossAmount: invoice.grossAmount,
            currency: invoice.currency, permanentStorageDate: invoice.permanentStorageDate, invoiceHash: invoice.invoiceHash,
            file: file, savedAt: KsefTime.iso(savedAt)
        )
        try append(Data(entry.jsonLine.utf8), to: dataDir.appendingPathComponent("index.jsonl"))
        saved.insert(invoice.ksefNumber)
        savedAtMillis.append(KsefTime.millis(savedAt))
    }

    func writeCheckpoint(_ value: String) throws {
        let json = JSONValue.object([("checkpoint", .string(value))]).compact() + "\n"
        try writeAtomic(Data(json.utf8), to: dataDir.appendingPathComponent("state.json"))
        checkpoint = value
    }
}
