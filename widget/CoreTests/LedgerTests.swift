import XCTest
@testable import KsefCore

private let NOW = instant("2026-11-26T08:00:00Z")
private let HWM = "2026-11-26T07:00:00.1234567+00:00"
private let NUMBER = "5265877635-20261120-0123456789AB-CD"
private let PINNED_LINE =
    "{\"ksefNumber\":\"\(NUMBER)\",\"subjectType\":\"Subject2\",\"issueDate\":\"2026-11-20\",\"invoiceType\":\"Vat\",\"currency\":\"PLN\","
    + "\"netAmount\":43.6,\"grossAmount\":53.63,\"vatAmount\":10.03}\n"

private func metadata(
    _ ksefNumber: String = NUMBER, issueDate: String = "2026-11-20", storedAt: String = "2026-11-20T09:00:00.1234567+00:00",
    net: Double? = 43.6, gross: Double = 53.63, vat: Double? = 10.03, type: String? = "Vat"
) -> InvoiceMetadata {
    InvoiceMetadata(
        ksefNumber: ksefNumber, invoiceNumber: "FV/1", issueDate: issueDate, permanentStorageDate: storedAt,
        seller: Seller(nip: "1111111111", name: "Sprzedawca"), grossAmount: gross, currency: "PLN", invoiceHash: "hash",
        netAmount: net, vatAmount: vat, invoiceType: type
    )
}

private func queries(
    _ windows: Locked<[Window]>, rateLimitedAt: Int? = nil, invoices: @escaping @Sendable (Window) -> [InvoiceMetadata] = { _ in [] }
) -> Query {
    { window, _ in
        let call = windows.update { listed in
            listed.append(window)
            return listed.count
        }
        if call == rateLimitedAt { throw RateLimitError(retryAfterSeconds: 900) }
        return MetadataPage(hasMore: false, isTruncated: false, permanentStorageHwmDate: window.to ?? HWM, invoices: invoices(window))
    }
}

final class LedgerTests: XCTestCase {
    private func sync(_ subject: Subject, _ ledger: Ledger, _ query: @escaping Query) async throws -> SyncOutcome {
        try await syncLedger(subject, ledger: ledger, query: query, year: 2026, now: { NOW })
    }

    func testGroszeAreExact() {
        XCTAssertEqual(grosze(43.6), 4360)
        XCTAssertEqual(grosze(-43.6), -4360)
        XCTAssertEqual(grosze(1234567.89), 123_456_789)
        XCTAssertEqual(grosze(9_999_999_999.99), 999_999_999_999)
        XCTAssertEqual(grosze(0.1)! + grosze(0.2)!, 30)
        XCTAssertEqual(grosze(0), 0)
        for invalid: Double in [1.005, .nan, .infinity, 1e10, -1e10] {
            XCTAssertNil(grosze(invalid), "\(invalid)")
        }
    }

    func testWritesTheLinePinnedInTheSpec() throws {
        let dir = try temporaryDirectory()
        let ledger = try Ledger.open(dataDir: dir)

        try ledger.add(ledgerEntry(metadata(), subject: .buyer))

        XCTAssertEqual(try text(dir.appendingPathComponent("ledger.jsonl")), PINNED_LINE)
    }

    func testStateKeepsItsKeyOrder() throws {
        let dir = try temporaryDirectory()
        let ledger = try Ledger.open(dataDir: dir)
        try ledger.add(ledgerEntry(metadata(), subject: .buyer))

        try ledger.writeCheckpoint(.seller, "b")
        try ledger.writeCheckpoint(.buyer, "a")
        try ledger.writeCompleteAt(instant("2026-11-26T13:00:41.123Z"))

        XCTAssertEqual(
            try text(dir.appendingPathComponent("ledger-state.json")),
            "{\"Subject2\":\"a\",\"Subject1\":\"b\",\"completeAt\":\"2026-11-26T13:00:41.123Z\"}\n"
        )
        let reopened = try Ledger.open(dataDir: dir)
        XCTAssertEqual(reopened.checkpoint(.buyer), "a")
        XCTAssertEqual(reopened.checkpoint(.seller), "b")
        XCTAssertEqual(reopened.completeAt, "2026-11-26T13:00:41.123Z")
        XCTAssertEqual(reopened.entries, ledger.entries)
        XCTAssertTrue(reopened.has(.buyer, NUMBER))
        XCTAssertFalse(reopened.has(.seller, NUMBER))
    }

    func testUnreadableFilesFailLoudly() throws {
        let ledgerFile: (URL) -> URL = { $0.appendingPathComponent("ledger.jsonl") }
        let truncated = try temporaryDirectory()
        try Data((PINNED_LINE + "{\"ksefNumber\":").utf8).write(to: ledgerFile(truncated))
        XCTAssertEqual(thrown { try Ledger.open(dataDir: truncated) }, "Uszkodzony plik ledger.jsonl, linia 2")

        let otherSubject = try temporaryDirectory()
        let line = PINNED_LINE.replacingOccurrences(of: "Subject2", with: "Subject3")
        try Data((PINNED_LINE + PINNED_LINE + line).utf8).write(to: ledgerFile(otherSubject))
        XCTAssertEqual(thrown { try Ledger.open(dataDir: otherSubject) }, "Uszkodzony plik ledger.jsonl, linia 3")

        let badState = try temporaryDirectory()
        try Data("[]".utf8).write(to: badState.appendingPathComponent("ledger-state.json"))
        XCTAssertEqual(thrown { try Ledger.open(dataDir: badState) }, "Uszkodzony plik ledger-state.json")

        let empty = try temporaryDirectory()
        let ledger = try Ledger.open(dataDir: empty)
        XCTAssertEqual(ledger.entries, [])
        XCTAssertNil(ledger.checkpoint(.buyer))
        XCTAssertNil(ledger.checkpoint(.seller))
        XCTAssertNil(ledger.completeAt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty.path), [])
    }

    private func thrown(_ body: () throws -> Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch {
            return errorMessage(error)
        }
    }

    func testRejectsMetadataItCannotSum() {
        let invalid = [
            metadata(net: nil), metadata(vat: nil), metadata(type: nil), metadata(gross: 1.005), metadata(issueDate: "2026-1-1"),
        ]
        for invoice in invalid {
            XCTAssertEqual(
                thrown { try ledgerEntry(invoice, subject: .buyer) },
                "Nieprawidłowe metadane faktury \"\(NUMBER)\" do podsumowania roku"
            )
        }
        XCTAssertEqual(
            thrown { try ledgerEntry(metadata("x", net: nil), subject: .buyer) }, "Nieprawidłowe metadane faktury \"x\" do podsumowania roku"
        )
    }

    func testStartsAtWarsawNewYearWithoutACheckpoint() async throws {
        let dir = try temporaryDirectory()
        let ledger = try Ledger.open(dataDir: dir)
        let windows = Locked<[Window]>([])
        let newYearsInvoice = metadata(issueDate: "2026-01-01", storedAt: "2025-12-31T23:30:00.0000000+00:00")

        let outcome = try await sync(.buyer, ledger, queries(windows) { $0.from == "2026-01-01T00:00:00+01:00" ? [newYearsInvoice] : [] })

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(windows.value.first?.from, "2026-01-01T00:00:00+01:00")
        XCTAssertEqual(windows.value.count, 4)
        XCTAssertEqual(windows.value.map { $0.to == nil }, [false, false, false, true])
        XCTAssertEqual(try text(dir.appendingPathComponent("ledger.jsonl")).split(separator: "\n").count, 1)
        XCTAssertEqual(ledger.checkpoint(.buyer), HWM)
    }

    func testResumesFromALaterCheckpointAndSkipsAnEarlierOne() async throws {
        let later = try Ledger.open(dataDir: try temporaryDirectory())
        try later.writeCheckpoint(.buyer, "2026-11-20T00:00:00.000Z")
        let laterWindows = Locked<[Window]>([])
        _ = try await sync(.buyer, later, queries(laterWindows))
        XCTAssertEqual(laterWindows.value.first?.from, "2026-11-20T00:00:00.000Z")

        let earlier = try Ledger.open(dataDir: try temporaryDirectory())
        try earlier.writeCheckpoint(.buyer, "2025-06-01T00:00:00.000Z")
        let earlierWindows = Locked<[Window]>([])
        _ = try await sync(.buyer, earlier, queries(earlierWindows))
        XCTAssertEqual(earlierWindows.value.first?.from, "2026-01-01T00:00:00+01:00")
    }

    func testAppendsEachInvoiceOnceAcrossReListedWindows() async throws {
        let dir = try temporaryDirectory()
        let invoice = metadata()
        let listsEverywhere = { @Sendable (_: Window) in [invoice] }

        _ = try await sync(.buyer, try Ledger.open(dataDir: dir), queries(Locked([]), invoices: listsEverywhere))
        XCTAssertEqual(try text(dir.appendingPathComponent("ledger.jsonl")), PINNED_LINE)

        let ledger = try Ledger.open(dataDir: dir)
        try ledger.writeCheckpoint(.buyer, "2026-01-01T00:00:00.000Z")
        _ = try await sync(.buyer, ledger, queries(Locked([]), invoices: listsEverywhere))
        XCTAssertEqual(try text(dir.appendingPathComponent("ledger.jsonl")), PINNED_LINE)
    }

    func testKeepsSubjectsApart() async throws {
        let dir = try temporaryDirectory()
        let ledger = try Ledger.open(dataDir: dir)
        let invoice = metadata()
        let listsEverywhere = { @Sendable (_: Window) in [invoice] }

        _ = try await sync(.buyer, ledger, queries(Locked([]), invoices: listsEverywhere))
        _ = try await sync(.seller, ledger, queries(Locked([]), invoices: listsEverywhere))

        let lines = try text(dir.appendingPathComponent("ledger.jsonl")).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"subjectType\":\"Subject2\""))
        XCTAssertTrue(lines[1].contains("\"subjectType\":\"Subject1\""))
        XCTAssertEqual(
            try text(dir.appendingPathComponent("ledger-state.json")), "{\"Subject2\":\"\(HWM)\",\"Subject1\":\"\(HWM)\"}\n"
        )
    }

    func testARateLimitIsPartialAndKeepsTheCheckpoint() async throws {
        let dir = try temporaryDirectory()
        let ledger = try Ledger.open(dataDir: dir)
        let windows = Locked<[Window]>([])
        let invoice = metadata()

        let outcome = try await sync(.buyer, ledger, queries(windows, rateLimitedAt: 2) { $0.from == "2026-01-01T00:00:00+01:00" ? [invoice] : [] })

        XCTAssertEqual(outcome, .partial("Limit zapytań KSeF — trzeba odczekać 900 s."))
        XCTAssertEqual(ledger.checkpoint(.buyer), windows.value[0].to)
        XCTAssertNotNil(windows.value[0].to)
        XCTAssertEqual(try text(dir.appendingPathComponent("ledger.jsonl")), PINNED_LINE)
    }

    func testNoTwoLedgerQueriesGoOutWithoutAPauseBetweenThem() async throws {
        let events = Locked<[String]>([])
        let query: (Subject) -> Query = { _ in
            { window, _ in
                events.update { $0.append("query") }
                return MetadataPage(hasMore: false, isTruncated: false, permanentStorageHwmDate: window.to ?? HWM, invoices: [])
            }
        }

        let completed = await updateLedger(
            dataDir: try temporaryDirectory(), query: query, now: { NOW },
            sleep: { milliseconds in events.update { $0.append("sleep \(milliseconds)") } }, log: { _ in }
        )

        XCTAssertTrue(completed)
        XCTAssertEqual(events.value, Array(repeating: ["sleep 500", "query"], count: 8).flatMap { $0 })
    }

    func testInvalidMetadataStopsBeforeTheCheckpoint() async throws {
        let dir = try temporaryDirectory()
        let ledger = try Ledger.open(dataDir: dir)
        let invoice = metadata(net: nil)

        let message = await thrownMessage { try await self.sync(.buyer, ledger, queries(Locked([])) { _ in [invoice] }) }

        XCTAssertEqual(message, "Nieprawidłowe metadane faktury \"\(NUMBER)\" do podsumowania roku")
        XCTAssertFalse(exists(dir.appendingPathComponent("ledger.jsonl")))
        XCTAssertFalse(exists(dir.appendingPathComponent("ledger-state.json")))
        XCTAssertNil(ledger.checkpoint(.buyer))
    }
}
