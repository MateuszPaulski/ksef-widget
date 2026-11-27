import XCTest
@testable import KsefCore

private let hwmLagMs = 180_000
private let maxAttempts = 2
private let attemptIntervalMs = 60_000

/// Sends a correcting and a EUR invoice to KSeF TEST to learn the real sign and currency conventions of the metadata
/// the ledger sums. Query budget for the seller's NIP: attempt 1 is 1 download + 4 + 4 ledger = 9, attempt 2 is 3.
final class SummaryProbeE2ETests: XCTestCase {
    func testACorrectionIsNegativeAndAForeignInvoiceKeepsItsCurrency() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 30 * 60
        let wait: @Sendable (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) }

        let dir = try temporaryDirectory()
        let sellerNip = randomNip()
        let buyerNip = randomNip()
        let seller = try TestCredentials.make(nip: sellerNip, keyType: .rsa, in: dir)
        let http = KsefHTTP(apiBase: KsefEnvironment.test.apiBase, transport: URLSessionTransport(), sleep: wait)
        let token = try await authenticate(
            http: http,
            credentials: loadCredentials(certificateURL: seller.certificateURL, keyURL: seller.keyURL, password: seller.password),
            nip: sellerNip, environment: .test, now: { Date() }, sleep: wait
        ).token

        let issueDate = warsawDay(Date())
        func number() -> String { "E2E/\((0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined())" }
        func values(_ extra: [String: String] = [:]) -> [String: String] {
            ["SELLER_NIP": sellerNip, "BUYER_NIP": buyerNip, "INVOICE_NUMBER": number(), "ISSUE_DATE": issueDate,
             "CREATED_AT": KsefTime.iso(Date().addingTimeInterval(-60))].merging(extra) { $1 }
        }

        let originalValues = values()
        let original = try await sendTestInvoice(
            http: http, accessToken: token, xml: invoiceTemplate("fa3-invoice.xml", replacing: originalValues), sleep: wait)
        trace("sent invoice \(original.ksefNumber)")
        let correction = try await sendTestInvoice(
            http: http, accessToken: token,
            xml: invoiceTemplate("fa3-correction.xml", replacing: values([
                "CORRECTED_NUMBER": originalValues["INVOICE_NUMBER"]!, "CORRECTED_ISSUE_DATE": issueDate,
                "CORRECTED_KSEF_NUMBER": original.ksefNumber,
            ])),
            sleep: wait)
        trace("sent correction \(correction.ksefNumber)")
        let foreign = try await sendTestInvoice(
            http: http, accessToken: token, xml: invoiceTemplate("fa3-invoice-eur.xml", replacing: values()), sleep: wait)
        trace("sent EUR invoice \(foreign.ksefNumber)")

        await wait(hwmLagMs)

        let dataDir = dir.appendingPathComponent("data")
        let snapshotURL = dir.appendingPathComponent("widget.json")
        let logs = Locked<[String]>([])
        let options = e2eRunOptions(
            nip: sellerNip, credentials: seller, dataDir: dataDir, startDate: issueDate,
            snapshotURL: snapshotURL, sleep: wait, notifications: Locked([]), logs: logs
        )
        var lines: [[String: Any]] = []
        for attempt in 1...maxAttempts {
            if attempt > 1 { await wait(attemptIntervalMs) }
            let result = await KsefCore.run(options)
            trace("attempt \(attempt): status=\(result.status.rawValue) reason=\(result.reason ?? "-")")
            lines = try ledgerLines(dataDir)
            if lines.count == 3 { break }
        }
        for line in lines { trace("ledger \(String(decoding: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), as: UTF8.self))") }
        guard lines.count == 3 else {
            throw KsefError("ledger has \(lines.count) lines after \(maxAttempts) attempts\n\(logs.value.joined(separator: "\n"))")
        }

        let byNumber = Dictionary(uniqueKeysWithValues: lines.map { ($0["ksefNumber"] as? String ?? "", $0) })
        let correctionLine = try XCTUnwrap(byNumber[correction.ksefNumber])
        XCTAssertEqual(correctionLine["subjectType"] as? String, "Subject1")
        XCTAssertEqual(correctionLine["invoiceType"] as? String, "Kor")
        XCTAssertEqual(correctionLine["netAmount"] as? Double, -43.6)
        XCTAssertEqual(correctionLine["grossAmount"] as? Double, -53.63)
        let foreignLine = try XCTUnwrap(byNumber[foreign.ksefNumber])
        XCTAssertEqual(foreignLine["currency"] as? String, "EUR")
        XCTAssertEqual(foreignLine["netAmount"] as? Double, 100)
        XCTAssertEqual(foreignLine["grossAmount"] as? Double, 123)
        trace("EUR vatAmount=\(foreignLine["vatAmount"] ?? "?") (98.42 means PLN, 23 means EUR)")

        let summary = try snapshotYearSummary(snapshotURL)
        XCTAssertEqual(summary.text, "\(issueDate.prefix(4)) netto · wydatki 0,00 PLN · przychody 0,00 PLN + 100,00 EUR")
    }
}
