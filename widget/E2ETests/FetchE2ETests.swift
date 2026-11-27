import XCTest
@testable import KsefCore

// Query budget for the buyer's NIP against the 20 per hour: attempt 1 is 2 download + 4 + 4 ledger = 10, every later
// attempt and the second run 3, worst case 19. From 27 December each subject needs 5 windows (21): do not run then.
private let hwmLagMs = 180_000
private let maxAttempts = 3
private let attemptIntervalMs = 60_000
private let backfillDays = 100

func trace(_ line: String) {
    print(line)
    fflush(stdout)
}

/// Prints each metadata query and answer, because TEST allows only 20 of them per hour and a failure needs the evidence.
struct MetadataTracingTransport: HTTPTransport {
    let inner: any HTTPTransport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await inner.send(request)
        guard request.url?.path.hasSuffix("/invoices/query/metadata") == true else { return (data, response) }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let dateRange = body?["dateRange"] as? [String: Any]
        let window = "\(body?["subjectType"] ?? "?") from=\(dateRange?["from"] ?? "?") to=\(dateRange?["to"] ?? "(none)")"
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if response.statusCode == 200, let answer {
            let count = (answer["invoices"] as? [Any])?.count ?? -1
            trace(
                "metadata \(response.statusCode) \(window) hasMore=\(answer["hasMore"] ?? "?") isTruncated=\(answer["isTruncated"] ?? "?") "
                    + "hwm=\(answer["permanentStorageHwmDate"] ?? "?") invoices=\(count)"
            )
            for case let invoice as [String: Any] in answer["invoices"] as? [Any] ?? [] {
                let fields = ["invoiceType", "currency", "netAmount", "grossAmount", "vatAmount", "issueDate"]
                trace("  invoice \(invoice["ksefNumber"] ?? "?") " + fields.map { "\($0)=\(invoice[$0] ?? "-")" }.joined(separator: " "))
            }
        } else {
            trace("metadata \(response.statusCode) \(window) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return (data, response)
    }
}

func e2eRunOptions(
    nip: String, credentials: TestCredentialFiles, dataDir: URL, startDate: String, snapshotURL: URL,
    sleep: @escaping @Sendable (Int) async -> Void,
    notifications: Locked<[(title: String, message: String)]>, logs: Locked<[String]>
) -> RunOptions {
    RunOptions(
        settings: Settings(nip: nip, environment: .test, startDate: startDate, dataDir: dataDir.path, verified: true),
        certificateURL: credentials.certificateURL, keyURL: credentials.keyURL, keyPassword: credentials.password,
        transport: MetadataTracingTransport(inner: URLSessionTransport()), sleep: sleep, now: { Date() },
        notify: { title, message in notifications.update { $0.append((title, message)) } },
        log: { line in logs.update { $0.append(line) } },
        snapshotURL: snapshotURL
    )
}

func ledgerLines(_ dataDir: URL) throws -> [[String: Any]] {
    let file = dataDir.appendingPathComponent("ledger.jsonl")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
}

func snapshotYearSummary(_ snapshotURL: URL) throws -> (text: String?, warning: Bool?) {
    let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any])
    let summary = snapshot["yearSummary"] as? [String: Any]
    return (summary?["text"] as? String, summary?["warning"] as? Bool)
}

/// Full fetch against KSeF TEST: one NIP sends an invoice to another, the fetcher downloads it. TEST only, random NIPs.
final class FetchE2ETests: XCTestCase {
    func testFetchesAnInvoiceSentByAnotherNipThenFindsNothingNew() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 30 * 60
        let wait: @Sendable (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) }

        let dir = try temporaryDirectory()
        let sellerNip = randomNip()
        let buyerNip = randomNip()
        let seller = try TestCredentials.make(nip: sellerNip, keyType: .rsa, in: dir)
        let buyer = try TestCredentials.make(nip: buyerNip, keyType: .ec, in: dir)
        let http = KsefHTTP(apiBase: KsefEnvironment.test.apiBase, transport: URLSessionTransport(), sleep: wait)

        let sellerToken = try await authenticate(
            http: http,
            credentials: loadCredentials(certificateURL: seller.certificateURL, keyURL: seller.keyURL, password: seller.password),
            nip: sellerNip, environment: .test, now: { Date() }, sleep: wait
        )
        let invoiceNumber = "E2E/\((0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined())"
        let xml = try invoiceTemplate("fa3-invoice.xml", replacing: [
            "SELLER_NIP": sellerNip, "BUYER_NIP": buyerNip, "INVOICE_NUMBER": invoiceNumber,
            "ISSUE_DATE": warsawDay(Date()), "CREATED_AT": KsefTime.iso(Date().addingTimeInterval(-60)),
        ])
        let sent = try await sendTestInvoice(http: http, accessToken: sellerToken.token, xml: xml, sleep: wait)
        let ksefNumber = sent.ksefNumber
        trace("sent invoice \(ksefNumber) at \(KsefTime.iso(Date()))")

        await wait(hwmLagMs)

        let dataDir = dir.appendingPathComponent("data")
        // 100 days back: the first run walks one closed window (explicit `to`) and then the open one.
        let startDate = warsawDay(Date().addingTimeInterval(-Double(backfillDays) * 86_400))
        let notifications = Locked<[(title: String, message: String)]>([])
        let logs = Locked<[String]>([])
        let options = e2eRunOptions(
            nip: buyerNip, credentials: buyer, dataDir: dataDir, startDate: startDate,
            snapshotURL: dir.appendingPathComponent("widget.json"), sleep: wait, notifications: notifications, logs: logs
        )

        var summary: RunSummary?
        for attempt in 1...maxAttempts {
            if attempt > 1 { await wait(attemptIntervalMs) }
            let result = await KsefCore.run(options)
            trace("attempt \(attempt): status=\(result.status.rawValue) saved=\(result.saved.map(\.ksefNumber)) reason=\(result.reason ?? "-")")
            guard result.status == .complete else {
                throw KsefError("attempt \(attempt): \(result.status.rawValue) \(result.reason ?? "")\n\(logs.value.joined(separator: "\n"))")
            }
            if attempt == 1 {
                XCTAssertTrue(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("state.json").path), "the closed window advanced the checkpoint")
            }
            summary = result
            if result.saved.contains(where: { $0.ksefNumber == ksefNumber }) { break }
        }
        XCTAssertTrue(
            summary?.saved.contains { $0.ksefNumber == ksefNumber } == true,
            "invoice \(ksefNumber) not fetched after \(maxAttempts) attempts"
        )

        let day = warsawDay(Date()).split(separator: "-").map(String.init)
        let saved = try Data(contentsOf: dataDir.appendingPathComponent("invoices/\(day[0])/\(day[1])/\(ksefNumber).xml"))
        XCTAssertEqual(saved, xml, "saved XML differs from the XML that was sent")

        let indexLines = try String(contentsOf: dataDir.appendingPathComponent("index.jsonl"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        XCTAssertEqual(indexLines.count, 1)
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(indexLines[0].utf8)) as? [String: Any])
        XCTAssertEqual(entry["ksefNumber"] as? String, ksefNumber)
        XCTAssertEqual(entry["sellerNip"] as? String, sellerNip)

        let report = try String(contentsOf: dataDir.appendingPathComponent("reports/\(warsawDay(Date())).md"), encoding: .utf8)
        XCTAssertTrue(report.contains(invoiceNumber))
        XCTAssertTrue(report.contains("https://qr-test.ksef.mf.gov.pl/invoice/\(sellerNip)/"))
        XCTAssertEqual(notifications.value.last?.title, "KSeF: 1 nowa faktura")

        let year = String(warsawDay(Date()).prefix(4))
        let buyerLedger = try ledgerLines(dataDir)
        XCTAssertEqual(buyerLedger.count, 1)
        try assertLedgerLine(buyerLedger.first, subject: "Subject2", ksefNumber: ksefNumber)
        let buyerSummary = try snapshotYearSummary(dir.appendingPathComponent("widget.json"))
        XCTAssertEqual(buyerSummary.text, "\(year) · wydatki 43,60 PLN · przychody 0,00 PLN")
        XCTAssertEqual(buyerSummary.warning, false)

        let notificationsBefore = notifications.value.count
        let second = await KsefCore.run(options)
        trace("second run: status=\(second.status.rawValue) saved=\(second.saved.count) reason=\(second.reason ?? "-")")
        XCTAssertEqual(second.status, .complete, "\(second.reason ?? "")\n\(logs.value.joined(separator: "\n"))")
        XCTAssertEqual(second.saved.count, 0)
        XCTAssertEqual(notifications.value.count, notificationsBefore)
        XCTAssertEqual(
            try String(contentsOf: dataDir.appendingPathComponent("index.jsonl"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").count,
            1
        )

        let sellerDataDir = dir.appendingPathComponent("seller-data")
        let sellerSnapshot = dir.appendingPathComponent("seller-widget.json")
        let sellerLogs = Locked<[String]>([])
        let sellerRun = await KsefCore.run(e2eRunOptions(
            nip: sellerNip, credentials: seller, dataDir: sellerDataDir, startDate: warsawDay(Date()),
            snapshotURL: sellerSnapshot, sleep: wait, notifications: Locked([]), logs: sellerLogs
        ))
        trace("seller run: status=\(sellerRun.status.rawValue) saved=\(sellerRun.saved.count) reason=\(sellerRun.reason ?? "-")")
        XCTAssertEqual(sellerRun.status, .complete, "\(sellerRun.reason ?? "")\n\(sellerLogs.value.joined(separator: "\n"))")
        XCTAssertEqual(sellerRun.saved.count, 0)
        let sellerLedger = try ledgerLines(sellerDataDir)
        XCTAssertEqual(sellerLedger.count, 1)
        try assertLedgerLine(sellerLedger.first, subject: "Subject1", ksefNumber: ksefNumber)
        let sellerSummary = try snapshotYearSummary(sellerSnapshot)
        XCTAssertEqual(sellerSummary.text, "\(year) · wydatki 0,00 PLN · przychody 43,60 PLN")
        XCTAssertEqual(sellerSummary.warning, false)
    }

    private func assertLedgerLine(_ line: [String: Any]?, subject: String, ksefNumber: String) throws {
        let line = try XCTUnwrap(line)
        XCTAssertEqual(line["subjectType"] as? String, subject)
        XCTAssertEqual(line["ksefNumber"] as? String, ksefNumber)
        XCTAssertEqual(line["invoiceType"] as? String, "Vat")
        XCTAssertEqual(line["currency"] as? String, "PLN")
        XCTAssertEqual(line["netAmount"] as? Double, 43.6)
        XCTAssertEqual(line["grossAmount"] as? Double, 53.63)
        XCTAssertEqual(line["vatAmount"] as? Double, 10.03)
    }
}
