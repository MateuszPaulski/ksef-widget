import XCTest
@testable import KsefCore

private let hwmLagMs = 120_000
private let maxAttempts = 4
private let attemptIntervalMs = 60_000
private let backfillDays = 100

private func trace(_ line: String) {
    print(line)
    fflush(stdout)
}

/// Prints each metadata query and answer, because TEST allows only 20 of them per hour and a failure needs the evidence.
private struct MetadataTracingTransport: HTTPTransport {
    let inner: any HTTPTransport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await inner.send(request)
        guard request.url?.path.hasSuffix("/invoices/query/metadata") == true else { return (data, response) }
        let dateRange = (request.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["dateRange"]) as? [String: Any]
        let window = "from=\(dateRange?["from"] ?? "?") to=\(dateRange?["to"] ?? "(none)")"
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if response.statusCode == 200, let answer {
            let count = (answer["invoices"] as? [Any])?.count ?? -1
            trace(
                "metadata \(response.statusCode) \(window) hasMore=\(answer["hasMore"] ?? "?") isTruncated=\(answer["isTruncated"] ?? "?") "
                    + "hwm=\(answer["permanentStorageHwmDate"] ?? "?") invoices=\(count)"
            )
        } else {
            trace("metadata \(response.statusCode) \(window) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return (data, response)
    }
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
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let template = try String(contentsOf: repositoryRoot.appendingPathComponent("test/fixtures/fa3-invoice.xml"), encoding: .utf8)
        let xml = Data(
            template
                .replacingOccurrences(of: "{{SELLER_NIP}}", with: sellerNip)
                .replacingOccurrences(of: "{{BUYER_NIP}}", with: buyerNip)
                .replacingOccurrences(of: "{{INVOICE_NUMBER}}", with: invoiceNumber)
                .replacingOccurrences(of: "{{ISSUE_DATE}}", with: warsawDay(Date()))
                .replacingOccurrences(of: "{{CREATED_AT}}", with: KsefTime.iso(Date().addingTimeInterval(-60)))
                .utf8
        )
        let sent = try await sendTestInvoice(http: http, accessToken: sellerToken.token, xml: xml, sleep: wait)
        let ksefNumber = sent.ksefNumber
        trace("sent invoice \(ksefNumber) at \(KsefTime.iso(Date()))")

        await wait(hwmLagMs)

        let dataDir = dir.appendingPathComponent("data")
        let settings = Settings(
            nip: buyerNip, environment: .test,
            // 100 days back: the first run walks one closed window (explicit `to`) and then the open one.
            startDate: warsawDay(Date().addingTimeInterval(-Double(backfillDays) * 86_400)),
            dataDir: dataDir.path, verified: true
        )
        let notifications = Locked<[(title: String, message: String)]>([])
        let logs = Locked<[String]>([])
        let options = RunOptions(
            settings: settings, certificateURL: buyer.certificateURL, keyURL: buyer.keyURL, keyPassword: buyer.password,
            transport: MetadataTracingTransport(inner: URLSessionTransport()), sleep: wait, now: { Date() },
            notify: { title, message in notifications.update { $0.append((title, message)) } },
            log: { line in logs.update { $0.append(line) } },
            snapshotURL: dir.appendingPathComponent("widget.json")
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
    }
}
