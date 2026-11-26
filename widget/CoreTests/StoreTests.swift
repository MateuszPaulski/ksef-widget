import XCTest
@testable import KsefCore

final class StoreTests: XCTestCase {
    private let now = instant("2026-11-26T08:00:12.345Z")
    private let ksefNumber = "5265877635-20261120-0123456789AB-CD"
    private var invoice: InvoiceMetadata {
        InvoiceMetadata(
            ksefNumber: ksefNumber, invoiceNumber: "FV/1/2026", issueDate: "2026-11-20",
            permanentStorageDate: "2026-11-20T09:00:00.1234567+00:00", seller: Seller(nip: "1111111111", name: "Sprzedawca"),
            grossAmount: 123.45, currency: "PLN", invoiceHash: "aGFzaA=="
        )
    }

    private func dataDir() throws -> URL {
        try temporaryDirectory().appendingPathComponent("data")
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func names(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func open(_ dir: URL, at time: Date? = nil) throws -> Store {
        let moment = time ?? now
        return try Store.open(dataDir: dir, now: { moment })
    }

    private func with(_ number: String, of invoice: InvoiceMetadata) -> InvoiceMetadata {
        InvoiceMetadata(
            ksefNumber: number, invoiceNumber: invoice.invoiceNumber, issueDate: invoice.issueDate,
            permanentStorageDate: invoice.permanentStorageDate, seller: invoice.seller, grossAmount: invoice.grossAmount,
            currency: invoice.currency, invoiceHash: invoice.invoiceHash
        )
    }

    func testOpeningAMissingDataDirCreatesNothing() throws {
        let dir = try dataDir()
        let store = try open(dir)
        XCTAssertNil(store.checkpoint)
        XCTAssertFalse(store.has("x"))
        XCTAssertFalse(exists(dir))
    }

    func testSavesInvoiceBytesAndIndexesThem() throws {
        let dir = try dataDir()
        let store = try open(dir)
        let xml = Data("<Faktura>\r\nł</Faktura>".utf8)

        try store.saveInvoice(invoice, xml: xml)

        let file = "invoices/2026/11/\(ksefNumber).xml"
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(file)), xml)
        let lines = try text(dir.appendingPathComponent("index.jsonl")).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1], "")
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? NSDictionary)
        XCTAssertEqual(entry, [
            "ksefNumber": ksefNumber,
            "invoiceNumber": "FV/1/2026",
            "issueDate": "2026-11-20",
            "sellerNip": "1111111111",
            "sellerName": "Sprzedawca",
            "grossAmount": 123.45,
            "currency": "PLN",
            "permanentStorageDate": "2026-11-20T09:00:00.1234567+00:00",
            "invoiceHash": "aGFzaA==",
            "file": file,
            "savedAt": "2026-11-26T08:00:12.345Z",
        ] as NSDictionary)
        XCTAssertTrue(store.has(ksefNumber))
        XCTAssertEqual(try names(in: dir.appendingPathComponent("invoices/2026/11")), ["\(ksefNumber).xml"])
    }

    func testWritesANullSellerNameWhenKSeFGivesNone() throws {
        let dir = try dataDir()
        let store = try open(dir)
        let nameless = InvoiceMetadata(
            ksefNumber: ksefNumber, invoiceNumber: "FV/1/2026", issueDate: "2026-11-20",
            permanentStorageDate: "2026-11-20T09:00:00.1234567+00:00", seller: Seller(nip: "1111111111", name: nil),
            grossAmount: 123.45, currency: "PLN", invoiceHash: "aGFzaA=="
        )
        try store.saveInvoice(nameless, xml: Data("x".utf8))
        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(dir.appendingPathComponent("index.jsonl")).utf8)) as? NSDictionary)
        XCTAssertEqual(line["sellerName"] as? NSNull, NSNull())
    }

    func testReopeningKeepsTheDedupSet() throws {
        let dir = try dataDir()
        try open(dir).saveInvoice(invoice, xml: Data("x".utf8))
        let reopened = try open(dir)
        XCTAssertTrue(reopened.has(ksefNumber))
        XCTAssertFalse(reopened.has("other"))
    }

    func testSavedSinceCountsSavesOfEarlierRunsAndOfThisOne() throws {
        let dir = try dataDir()
        try open(dir, at: instant("2026-11-26T07:00:00Z")).saveInvoice(invoice, xml: Data("x".utf8))
        try open(dir, at: instant("2026-11-26T07:45:00Z")).saveInvoice(with("second", of: invoice), xml: Data("y".utf8))

        let store = try open(dir, at: instant("2026-11-26T08:00:00Z"))
        try store.saveInvoice(with("third", of: invoice), xml: Data("z".utf8))

        XCTAssertEqual(store.savedSince(instant("2026-11-26T06:00:00Z")), 3)
        XCTAssertEqual(store.savedSince(instant("2026-11-26T07:30:00Z")), 2)
        XCTAssertEqual(store.savedSince(instant("2026-11-26T07:45:00Z")), 1)
        XCTAssertEqual(store.savedSince(instant("2026-11-26T08:00:00Z")), 0)
    }

    func testStoresTheCheckpointVerbatim() throws {
        let dir = try dataDir()
        let store = try open(dir)
        try store.writeCheckpoint("2026-11-26T07:00:00.1234567+00:00")
        XCTAssertEqual(store.checkpoint, "2026-11-26T07:00:00.1234567+00:00")
        XCTAssertEqual(try open(dir).checkpoint, "2026-11-26T07:00:00.1234567+00:00")
        XCTAssertEqual(try names(in: dir), ["state.json"])
    }

    private func writeCorruptIndex(_ dir: URL) throws {
        let golden = try FormatsFixture.load()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((golden.indexLines[0] + "{\"ksefNumber\":\n").utf8).write(to: dir.appendingPathComponent("index.jsonl"))
    }

    func testACorruptIndexLineFailsLoudly() throws {
        let dir = try dataDir()
        try writeCorruptIndex(dir)
        XCTAssertThrowsError(try open(dir)) { XCTAssertEqual(errorMessage($0), "Uszkodzony plik index.jsonl, linia 2") }
    }

    func testReadIndexReturnsEntriesInFileOrder() throws {
        let dir = try dataDir()
        let store = try open(dir)
        try store.saveInvoice(invoice, xml: Data("x".utf8))
        try store.saveInvoice(with("second", of: invoice), xml: Data("y".utf8))

        let entries = try readIndex(dataDir: dir)

        XCTAssertEqual(entries.map(\.ksefNumber), [ksefNumber, "second"])
        XCTAssertEqual(entries[0].savedAt, "2026-11-26T08:00:12.345Z")
    }

    func testReadIndexOfAMissingIndexIsEmpty() throws {
        let dir = try dataDir()
        XCTAssertEqual(try readIndex(dataDir: dir), [])
        XCTAssertFalse(exists(dir))
    }

    func testReadIndexFailsLoudlyOnACorruptLine() throws {
        let dir = try dataDir()
        try writeCorruptIndex(dir)
        XCTAssertThrowsError(try readIndex(dataDir: dir)) { XCTAssertEqual(errorMessage($0), "Uszkodzony plik index.jsonl, linia 2") }
    }

    func testAppendReportAppendsNeverOverwrites() throws {
        let dir = try dataDir()
        try appendReport(dataDir: dir, day: "2026-11-26", section: "section one")
        try appendReport(dataDir: dir, day: "2026-11-26", section: "section two")
        XCTAssertEqual(
            try text(dir.appendingPathComponent("reports/2026-11-26.md")),
            "# Faktury z KSeF — 2026-11-26\n\nsection one\nsection two\n"
        )
    }

    func testWritesTheTypeScriptBytes() throws {
        let golden = try FormatsFixture.load()
        let dir = try dataDir()
        let store = try open(dir, at: instant(golden.now))

        for invoice in golden.invoices { try store.saveInvoice(invoice, xml: Data("<x/>".utf8)) }
        try store.writeCheckpoint("2026-11-26T07:00:00.1234567+00:00")

        XCTAssertEqual(try text(dir.appendingPathComponent("index.jsonl")), golden.indexLines.joined())
        XCTAssertEqual(try text(dir.appendingPathComponent("state.json")), golden.stateJson)
    }

    func testReadsATypeScriptDataFolder() throws {
        let golden = try FormatsFixture.load()
        let dir = try dataDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(golden.indexLines.joined().utf8).write(to: dir.appendingPathComponent("index.jsonl"))
        try Data(golden.stateJson.utf8).write(to: dir.appendingPathComponent("state.json"))

        let store = try open(dir)

        XCTAssertEqual(store.checkpoint, "2026-11-26T07:00:00.1234567+00:00")
        for invoice in golden.invoices { XCTAssertTrue(store.has(invoice.ksefNumber)) }
        let entries = try readIndex(dataDir: dir)
        XCTAssertEqual(entries.count, 3)
        XCTAssertNil(entries[1].sellerName)
        XCTAssertEqual(entries[2].sellerName, golden.invoices[2].seller.name)
    }

    func testAShortIndexLineFailsLoudly() throws {
        let dir = try dataDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"ksefNumber\":\"x\"}\n".utf8).write(to: dir.appendingPathComponent("index.jsonl"))
        XCTAssertThrowsError(try readIndex(dataDir: dir)) { XCTAssertEqual(errorMessage($0), "Uszkodzony plik index.jsonl, linia 1") }
    }
}
