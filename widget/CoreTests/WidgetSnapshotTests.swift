import XCTest
@testable import KsefCore

final class WidgetSnapshotTests: XCTestCase {
    private let now = instant("2026-11-26T13:00:00.000Z")
    private let invoiceHash = "UtQp9Gpc51y+u3xApZjIjgkpZ01js+J8KflSPW8WzIE="

    private func entry(_ n: Int, _ savedAt: String, sellerName: String? = nil, named: Bool = true) -> IndexEntry {
        IndexEntry(
            ksefNumber: "K\(n)", invoiceNumber: "FV/\(n)", issueDate: "2026-11-20", sellerNip: "1111111111",
            sellerName: named ? (sellerName ?? "Sprzedawca \(n)") : nil, grossAmount: 1230, currency: "PLN",
            permanentStorageDate: "2026-11-20T09:00:00.1234567+00:00", invoiceHash: invoiceHash,
            file: "invoices/2026/11/K\(n).xml", savedAt: savedAt
        )
    }

    private func ten() -> [WidgetInvoice] {
        (1...10).map { widgetInvoice(entry($0, "2026-11-26T12:00:00.000Z"), .prod) }
    }

    private func snapshotFile() throws -> URL {
        try temporaryDirectory().appendingPathComponent("a/b/widget.json")
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testWidgetInvoiceMapsAnIndexEntryForDisplay() {
        XCTAssertEqual(
            widgetInvoice(entry(1, "2026-11-26T13:00:39.000Z"), .prod),
            WidgetInvoice(
                ksefNumber: "K1", seller: "Sprzedawca 1", invoiceNumber: "FV/1", amount: "1230,00 PLN", issueDate: "2026-11-20",
                savedAt: "2026-11-26T13:00:39.000Z",
                viewUrl: "https://qr.ksef.mf.gov.pl/invoice/1111111111/20-11-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE"
            )
        )
    }

    func testWidgetInvoiceFallsBackToTheNIP() {
        XCTAssertEqual(widgetInvoice(entry(1, "2026-11-26T13:00:39.000Z", named: false), .prod).seller, "NIP 1111111111")
    }

    func testKeepsTheNewest8NewestFirst() {
        let snapshot = buildSnapshot(status: .complete, reason: nil, failureKey: nil, invoices: ten(), now: now)
        XCTAssertEqual(snapshot.invoices.map(\.ksefNumber), ["K10", "K9", "K8", "K7", "K6", "K5", "K4", "K3"])
    }

    func testCountsTodaysSavesOverTheWholeIndex() {
        let snapshot = buildSnapshot(status: .complete, reason: nil, failureKey: nil, invoices: ten(), now: now)
        XCTAssertEqual(snapshot.savedToday, 10)
        XCTAssertEqual(snapshot.invoices.count, 8)
    }

    func testUsesTheWarsawDay() {
        let invoices = [
            widgetInvoice(entry(1, "2026-11-26T22:50:00.000Z"), .prod),
            widgetInvoice(entry(2, "2026-11-26T23:10:00.000Z"), .prod),
        ]
        let snapshot = buildSnapshot(status: .complete, reason: nil, failureKey: nil, invoices: invoices, now: instant("2026-11-26T23:30:00.000Z"))
        XCTAssertEqual(snapshot.today, "2026-11-27")
        XCTAssertEqual(snapshot.savedToday, 1)
    }

    func testCarriesStatusAndReason() {
        let failed = buildSnapshot(status: .failed, reason: "Brak połączenia z KSeF: fetch failed", failureKey: nil, invoices: [], now: now)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.reason, "Brak połączenia z KSeF: fetch failed")
        XCTAssertEqual(failed.updatedAt, "2026-11-26T13:00:00.000Z")
        XCTAssertNil(buildSnapshot(status: .complete, reason: nil, failureKey: nil, invoices: [], now: now).reason)
    }

    func testWriteSnapshotWritesPrettyJSONAtomically() throws {
        let url = try snapshotFile()
        let snapshot = buildSnapshot(
            status: .partial, reason: "x", failureKey: nil,
            invoices: [widgetInvoice(entry(1, "2026-11-26T12:00:00.000Z"), .prod)], now: now
        )

        try writeSnapshot(snapshot, to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), """
            {
              "updatedAt": "2026-11-26T13:00:00.000Z",
              "status": "partial",
              "reason": "x",
              "today": "2026-11-26",
              "savedToday": 1,
              "invoices": [
                {
                  "ksefNumber": "K1",
                  "seller": "Sprzedawca 1",
                  "invoiceNumber": "FV/1",
                  "amount": "1230,00 PLN",
                  "issueDate": "2026-11-20",
                  "savedAt": "2026-11-26T12:00:00.000Z",
                  "viewUrl": "https://qr.ksef.mf.gov.pl/invoice/1111111111/20-11-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE"
                }
              ]
            }

            """)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["widget.json"])
    }

    func testBuildSnapshotWritesFailureKeyOnlyWhenGiven() {
        XCTAssertEqual(buildSnapshot(status: .failed, reason: "long text", failureKey: "KSeF 500", invoices: [], now: now).failureKey, "KSeF 500")
        XCTAssertNil(buildSnapshot(status: .partial, reason: "x", failureKey: nil, invoices: [], now: now).failureKey)
    }

    func testReadPreviousFailureReturnsTheFailureKeyAndDayOfAFailedSnapshot() throws {
        let url = try snapshotFile()
        try writeSnapshot(buildSnapshot(status: .failed, reason: "long text", failureKey: "KSeF 500", invoices: [], now: now), to: url)
        let previous = readPreviousFailure(url)
        XCTAssertEqual(previous?.failureKey, "KSeF 500")
        XCTAssertEqual(previous?.today, "2026-11-26")
    }

    func testReadPreviousFailureIsNilUnlessTheFileIsAFailedSnapshot() throws {
        let url = try snapshotFile()
        XCTAssertNil(readPreviousFailure(url))
        try writeSnapshot(buildSnapshot(status: .partial, reason: "x", failureKey: nil, invoices: [], now: now), to: url)
        XCTAssertNil(readPreviousFailure(url))
        let garbage = [
            "{\"status\":\"failed\"", "null", "\"failed\"", "{\"status\":\"failed\",\"today\":\"2026-11-26\"}",
            "{\"status\":\"failed\",\"failureKey\":\"x\"}", "{\"status\":\"failed\",\"reason\":\"x\",\"today\":\"2026-11-26\"}",
        ]
        for text in garbage {
            try Data(text.utf8).write(to: url)
            XCTAssertNil(readPreviousFailure(url), text)
        }
    }

    func testWritesTheTypeScriptBytes() throws {
        let golden = try FormatsFixture.load()
        let entries = try golden.indexLines.map { try JSONDecoder().decode(IndexEntry.self, from: Data($0.utf8)) }
        let url = try snapshotFile()

        try writeSnapshot(
            buildSnapshot(
                status: .failed, reason: "Uwierzytelnienie w KSeF nieudane (kod 460: Błąd)", failureKey: "KSeF 500",
                invoices: entries.map { widgetInvoice($0, .prod) }, now: instant(golden.now)
            ),
            to: url
        )

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), golden.snapshotJson)
    }

    func testTheWidgetCanReadIt() throws {
        let url = try snapshotFile()
        try writeSnapshot(
            buildSnapshot(status: .partial, reason: "x", failureKey: "k", invoices: ten(), now: now), to: url
        )

        let object = try jsonObject(url)

        XCTAssertNoThrow(try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(XCTUnwrap(object["updatedAt"] as? String)))
        XCTAssertTrue(["complete", "partial", "failed"].contains(object["status"] as? String ?? ""))
        XCTAssertNotNil(object["reason"] as? String)
        XCTAssertNotNil(object["today"] as? String)
        XCTAssertEqual(object["savedToday"] as? Int, 10)
        let invoices = try XCTUnwrap(object["invoices"] as? [[String: Any]])
        XCTAssertEqual(invoices.count, 8)
        for invoice in invoices {
            for key in ["ksefNumber", "seller", "amount", "issueDate", "viewUrl"] {
                XCTAssertNotNil(invoice[key] as? String, key)
            }
        }
    }
}
