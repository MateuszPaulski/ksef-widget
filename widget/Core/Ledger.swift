import Foundation

private let maxGroszeMagnitude = 1e10  // PLN: keeps amount × 100 exact in a Double
private let groszeTolerance = 0.001

struct LedgerEntry: Decodable, Equatable {
    let ksefNumber: String
    let subjectType: Subject
    let issueDate: String
    let invoiceType: String
    let currency: String
    let netAmount: Double
    let grossAmount: Double
    let vatAmount: Double
}

/// Whole grosze, or nil for a value with more than two decimals, not finite, or ≥ 10¹⁰ PLN in magnitude.
func grosze(_ amount: Double) -> Int64? {
    guard amount.isFinite, abs(amount) < maxGroszeMagnitude else { return nil }
    let scaled = amount * 100
    let whole = scaled.rounded()
    return abs(scaled - whole) <= groszeTolerance ? Int64(whole) : nil
}

/// Throws `Nieprawidłowe metadane faktury <quoted> do podsumowania roku` unless the three amounts are whole grosze,
/// invoiceType is present and issueDate is YYYY-MM-DD.
func ledgerEntry(_ invoice: InvoiceMetadata, subject: Subject) throws -> LedgerEntry {
    guard let netAmount = invoice.netAmount, let vatAmount = invoice.vatAmount, let invoiceType = invoice.invoiceType,
          [netAmount, invoice.grossAmount, vatAmount].allSatisfy({ grosze($0) != nil }),
          invoice.issueDate.wholeMatch(of: issueDatePattern) != nil
    else { throw KsefError("Nieprawidłowe metadane faktury \(quoted(invoice.ksefNumber)) do podsumowania roku") }
    return LedgerEntry(
        ksefNumber: invoice.ksefNumber, subjectType: subject, issueDate: invoice.issueDate, invoiceType: invoiceType,
        currency: invoice.currency, netAmount: netAmount, grossAmount: invoice.grossAmount, vatAmount: vatAmount
    )
}

private struct LedgerState: Decodable {
    let buyer: String?
    let seller: String?
    let completeAt: String?

    private enum CodingKeys: String, CodingKey {
        case buyer = "Subject2", seller = "Subject1", completeAt
    }
}

/// Used by one run at a time.
final class Ledger {
    private let dataDir: URL
    private var checkpoints: [Subject: String]
    private var known: Set<String>
    private(set) var entries: [LedgerEntry]
    private(set) var completeAt: String?

    private init(dataDir: URL, entries: [LedgerEntry], checkpoints: [Subject: String], completeAt: String?) {
        self.dataDir = dataDir
        self.entries = entries
        self.checkpoints = checkpoints
        self.completeAt = completeAt
        known = Set(entries.map { Self.key($0.subjectType, $0.ksefNumber) })
    }

    static func open(dataDir: URL) throws -> Ledger {
        var entries: [LedgerEntry] = []
        if let data = try readIfExists(dataDir.appendingPathComponent("ledger.jsonl")) {
            let decoder = JSONDecoder()
            // Split on the newline byte only, as readIndex does.
            for (offset, line) in data.split(separator: newline, omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
                guard let entry = try? decoder.decode(LedgerEntry.self, from: Data(line)) else {
                    throw KsefError("Uszkodzony plik ledger.jsonl, linia \(offset + 1)")
                }
                entries.append(entry)
            }
        }
        var checkpoints: [Subject: String] = [:]
        var completeAt: String?
        if let data = try readIfExists(dataDir.appendingPathComponent("ledger-state.json")) {
            guard let state = try? JSONDecoder().decode(LedgerState.self, from: data) else {
                throw KsefError("Uszkodzony plik ledger-state.json")
            }
            checkpoints[.buyer] = state.buyer
            checkpoints[.seller] = state.seller
            completeAt = state.completeAt
        }
        return Ledger(dataDir: dataDir, entries: entries, checkpoints: checkpoints, completeAt: completeAt)
    }

    func checkpoint(_ subject: Subject) -> String? { checkpoints[subject] }

    func has(_ subject: Subject, _ ksefNumber: String) -> Bool { known.contains(Self.key(subject, ksefNumber)) }

    /// Not `append`: a method of that name would shadow the free `append(_:to:)`.
    func add(_ entry: LedgerEntry) throws {
        let line = JSONValue.object([
            ("ksefNumber", .string(entry.ksefNumber)),
            ("subjectType", .string(entry.subjectType.rawValue)),
            ("issueDate", .string(entry.issueDate)),
            ("invoiceType", .string(entry.invoiceType)),
            ("currency", .string(entry.currency)),
            ("netAmount", .number(entry.netAmount)),
            ("grossAmount", .number(entry.grossAmount)),
            ("vatAmount", .number(entry.vatAmount)),
        ]).compact() + "\n"
        try append(Data(line.utf8), to: dataDir.appendingPathComponent("ledger.jsonl"))
        entries.append(entry)
        known.insert(Self.key(entry.subjectType, entry.ksefNumber))
    }

    func writeCheckpoint(_ subject: Subject, _ value: String) throws {
        var updated = checkpoints
        updated[subject] = value
        try writeState(checkpoints: updated, completeAt: completeAt)
        checkpoints = updated
    }

    func writeCompleteAt(_ instant: Date) throws {
        let value = KsefTime.iso(instant)
        try writeState(checkpoints: checkpoints, completeAt: value)
        completeAt = value
    }

    private func writeState(checkpoints: [Subject: String], completeAt: String?) throws {
        var fields: [(String, JSONValue)] = []
        for subject in [Subject.buyer, .seller] {
            if let checkpoint = checkpoints[subject] { fields.append((subject.rawValue, .string(checkpoint))) }
        }
        if let completeAt { fields.append(("completeAt", .string(completeAt))) }
        try writeAtomic(Data((JSONValue.object(fields).compact() + "\n").utf8), to: dataDir.appendingPathComponent("ledger-state.json"))
    }

    private static func key(_ subject: Subject, _ ksefNumber: String) -> String { "\(subject.rawValue) \(ksefNumber)" }
}

func yearStart(_ year: Int) -> String { "\(year)-01-01T00:00:00+01:00" }

func syncLedger(
    _ subject: Subject, ledger: Ledger, query: Query, year: Int, now: @Sendable () -> Date
) async throws -> SyncOutcome {
    let start = yearStart(year)
    var from = start
    if let checkpoint = ledger.checkpoint(subject), let checkpointMillis = KsefTime.millis(checkpoint),
       let startMillis = KsefTime.millis(start), checkpointMillis > startMillis {
        from = checkpoint
    }
    return try await walkWindows(
        from: from, query: query, now: now,
        process: { invoices in
            for invoice in invoices where !ledger.has(subject, invoice.ksefNumber) {
                try ledger.add(ledgerEntry(invoice, subject: subject))
            }
            return nil
        },
        writeCheckpoint: { try ledger.writeCheckpoint(subject, $0) }
    )
}
