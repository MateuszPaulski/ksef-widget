import Foundation

private let maxGroszeMagnitude = 1e10  // PLN: keeps amount × 100 exact in a Double
private let groszeTolerance = 0.001
private let ledgerQueryPauseMs = 500  // KSeF allows 8 metadata queries per second; this keeps the ledger at 2

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

/// An invoice whose metadata the ledger cannot sum; recorded in ledger-state.json so that it is neither retried nor logged again.
struct SkippedInvoice: Decodable, Equatable {
    let subjectType: Subject
    let ksefNumber: String
}

private struct LedgerState: Decodable {
    let buyer: String?
    let seller: String?
    let completeAt: String?
    let skipped: [SkippedInvoice]?

    private enum CodingKeys: String, CodingKey {
        case buyer = "Subject2", seller = "Subject1", completeAt, skipped
    }
}

/// Used by one run at a time.
final class Ledger {
    private let dataDir: URL
    private var checkpoints: [Subject: String]
    private var known: Set<String>
    private(set) var entries: [LedgerEntry]
    private(set) var completeAt: String?
    private(set) var skipped: [SkippedInvoice]

    private init(
        dataDir: URL, entries: [LedgerEntry], checkpoints: [Subject: String], completeAt: String?, skipped: [SkippedInvoice]
    ) {
        self.dataDir = dataDir
        self.entries = entries
        self.checkpoints = checkpoints
        self.completeAt = completeAt
        self.skipped = skipped
        known = Set(entries.map { Self.key($0.subjectType, $0.ksefNumber) })
            .union(skipped.map { Self.key($0.subjectType, $0.ksefNumber) })
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
        var skipped: [SkippedInvoice] = []
        if let data = try readIfExists(dataDir.appendingPathComponent("ledger-state.json")) {
            guard let state = try? JSONDecoder().decode(LedgerState.self, from: data) else {
                throw KsefError("Uszkodzony plik ledger-state.json")
            }
            checkpoints[.buyer] = state.buyer
            checkpoints[.seller] = state.seller
            completeAt = state.completeAt
            skipped = state.skipped ?? []
        }
        return Ledger(dataDir: dataDir, entries: entries, checkpoints: checkpoints, completeAt: completeAt, skipped: skipped)
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
        try writeState(checkpoints: updated, completeAt: completeAt, skipped: skipped)
        checkpoints = updated
    }

    func writeCompleteAt(_ instant: Date) throws {
        let value = KsefTime.iso(instant)
        try writeState(checkpoints: checkpoints, completeAt: value, skipped: skipped)
        completeAt = value
    }

    func skip(_ subject: Subject, _ ksefNumber: String) throws {
        let updated = skipped + [SkippedInvoice(subjectType: subject, ksefNumber: ksefNumber)]
        try writeState(checkpoints: checkpoints, completeAt: completeAt, skipped: updated)
        skipped = updated
        known.insert(Self.key(subject, ksefNumber))
    }

    private func writeState(checkpoints: [Subject: String], completeAt: String?, skipped: [SkippedInvoice]) throws {
        var fields: [(String, JSONValue)] = []
        for subject in [Subject.buyer, .seller] {
            if let checkpoint = checkpoints[subject] { fields.append((subject.rawValue, .string(checkpoint))) }
        }
        if let completeAt { fields.append(("completeAt", .string(completeAt))) }
        if !skipped.isEmpty {
            let items = skipped.map {
                JSONValue.object([("subjectType", .string($0.subjectType.rawValue)), ("ksefNumber", .string($0.ksefNumber))])
            }
            fields.append(("skipped", .array(items)))
        }
        try writeAtomic(Data((JSONValue.object(fields).compact() + "\n").utf8), to: dataDir.appendingPathComponent("ledger-state.json"))
    }

    private static func key(_ subject: Subject, _ ksefNumber: String) -> String { "\(subject.rawValue) \(ksefNumber)" }
}

func yearStart(_ year: Int) -> String { "\(year)-01-01T00:00:00+01:00" }

/// An invoice whose metadata cannot be summed is recorded as skipped and logged, unless its KSeF number is itself
/// malformed: that cannot be recorded safely, so the error stops the ledger.
func syncLedger(
    _ subject: Subject, ledger: Ledger, query: Query, year: Int, now: @Sendable () -> Date, log: @Sendable (String) -> Void
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
                let entry: LedgerEntry
                do {
                    entry = try ledgerEntry(invoice, subject: subject)
                } catch let error where invoice.ksefNumber.wholeMatch(of: ksefNumberPattern) != nil {
                    try ledger.skip(subject, invoice.ksefNumber)
                    log("ledger \(subject.rawValue) skipped \(quoted(invoice.ksefNumber)): \(errorMessage(error))")
                    continue
                }
                try ledger.add(entry)
            }
            return nil
        },
        writeCheckpoint: { try ledger.writeCheckpoint(subject, $0) }
    )
}

/// Never throws; true when both subjects reached the open window and completeAt was written.
/// Pauses before every metadata query, the first included, so that it stays under KSeF's 8 queries per second.
func updateLedger(
    dataDir: URL, query: (Subject) -> Query, now: @Sendable () -> Date, sleep: @escaping @Sendable (Int) async -> Void,
    log: @Sendable (String) -> Void
) async -> Bool {
    let ledger: Ledger
    do {
        ledger = try Ledger.open(dataDir: dataDir)
    } catch {
        log("ledger stopped: \(errorMessage(error))")
        return false
    }
    let year = warsawYear(now())
    for subject in [Subject.buyer, .seller] {
        let unpaced = query(subject)
        let paced: Query = { window, pageOffset in
            await sleep(ledgerQueryPauseMs)
            return try await unpaced(window, pageOffset)
        }
        do {
            if case .partial(let reason) = try await syncLedger(subject, ledger: ledger, query: paced, year: year, now: now, log: log) {
                log("ledger \(subject.rawValue) stopped: \(reason)")
                return false
            }
        } catch {
            log("ledger \(subject.rawValue) stopped: \(errorMessage(error))")
            return false
        }
    }
    do {
        try ledger.writeCompleteAt(now())
    } catch {
        log("ledger stopped: \(errorMessage(error))")
        return false
    }
    return true
}
