import XCTest
@testable import KsefCore

private let START = instant("2026-11-26T07:00:00Z")
private let HWM = "2026-11-26T06:59:00.1234567+00:00"

private struct Rig {
    let options: RunOptions
    let fake: FakeKsef
    let clock: FakeClock
    let dataDir: URL
    let snapshotURL: URL
    let notifications: Locked<[(title: String, message: String)]>
    let logs: Locked<[String]>
}

final class RunTests: XCTestCase {
    private var root: URL!
    private var files: TestCredentialFiles!
    override func setUpWithError() throws {
        root = try temporaryDirectory()
        files = try TestCredentials.make(nip: randomNip(), keyType: .rsa, in: root)
    }

    private func rig(
        invoices: [FakeInvoice] = [], salesInvoices: [FakeInvoice] = [], authStatus: FakeAuthStatus? = nil, fetchError: (any Error)? = nil,
        downloadStatus: (@Sendable (String) -> FakeDownloadAnswer?)? = nil, metadataAnswer: (@Sendable (String) -> FakeDownloadAnswer?)? = nil,
        keyPassword: String? = nil, dryRun: Bool = false, notify: (@Sendable (String, String) async throws -> Void)? = nil
    ) -> Rig {
        let clock = FakeClock(START)
        let id = UUID().uuidString
        let dataDir = root.appendingPathComponent("data-\(id)")
        let snapshotURL = root.appendingPathComponent("widget-\(id).json")
        let fake = FakeKsef(FakeKsefOptions(
            invoices: invoices, hwm: HWM, now: { clock.now }, authStatus: authStatus,
            downloadStatus: downloadStatus, fetchError: fetchError, salesInvoices: salesInvoices, metadataAnswer: metadataAnswer
        ))
        let notifications = Locked<[(title: String, message: String)]>([])
        let logs = Locked<[String]>([])
        let options = RunOptions(
            settings: Settings(nip: "5265877635", environment: .test, startDate: "2026-11-01", dataDir: dataDir.path, verified: true),
            certificateURL: files.certificateURL, keyURL: files.keyURL, keyPassword: keyPassword ?? files.password,
            transport: fake, sleep: { clock.sleep($0) }, now: { clock.now },
            notify: notify ?? { title, message in notifications.update { $0.append((title, message)) } },
            log: { line in logs.update { $0.append(line) } },
            snapshotURL: snapshotURL, dryRun: dryRun
        )
        return Rig(options: options, fake: fake, clock: clock, dataDir: dataDir, snapshotURL: snapshotURL, notifications: notifications, logs: logs)
    }

    private func reportURL(_ dataDir: URL) -> URL {
        dataDir.appendingPathComponent("reports/\(warsawDay(START)).md")
    }

    private func indexLines(_ dataDir: URL) throws -> [String] {
        try text(dataDir.appendingPathComponent("index.jsonl")).split(separator: "\n").map(String.init)
    }

    private func metadataQueries(_ r: Rig) async -> Int {
        await r.fake.requests.filter { $0.path.hasPrefix("/invoices/query/metadata") }.count
    }

    private func state(_ dataDir: URL) throws -> NSDictionary {
        try jsonObject(dataDir.appendingPathComponent("state.json")) as NSDictionary
    }

    func testSavesNewInvoicesReportsAndNotifiesOnce() async throws {
        let invoices = [fakeInvoice(1), fakeInvoice(2)]
        let r = rig(invoices: invoices)

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .complete)
        XCTAssertEqual(summary.saved.count, 2)
        for invoice in invoices {
            let saved = try Data(contentsOf: r.dataDir.appendingPathComponent("invoices/2026/11/\(invoice.metadata.ksefNumber).xml"))
            XCTAssertEqual(saved, invoice.xml)
        }
        XCTAssertEqual(try indexLines(r.dataDir).count, 2)
        XCTAssertEqual(try state(r.dataDir), ["checkpoint": HWM] as NSDictionary)
        let report = try text(reportURL(r.dataDir))
        XCTAssertTrue(report.contains("FV/1") && report.contains("FV/2"))
        XCTAssertTrue(report.contains("https://qr-test.ksef.mf.gov.pl/invoice/"))
        XCTAssertEqual(r.notifications.value.count, 1)
        XCTAssertEqual(r.notifications.value.first?.title, "KSeF: 2 nowe faktury")
        XCTAssertEqual(r.logs.value.count, 1)
        XCTAssertTrue(r.logs.value[0].contains("complete"))
    }

    func testASecondRunFindsNothingAndStaysQuiet() async throws {
        let r = rig(invoices: [fakeInvoice(1), fakeInvoice(2)])
        _ = await KsefCore.run(r.options)
        let reportBefore = try text(reportURL(r.dataDir))
        let downloadsBefore = await r.fake.ksefRequests.count

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .complete)
        XCTAssertEqual(summary.saved.count, 0)
        XCTAssertEqual(r.notifications.value.count, 1)
        XCTAssertEqual(try text(reportURL(r.dataDir)), reportBefore)
        XCTAssertEqual(try indexLines(r.dataDir).count, 2)
        let downloadsAfter = await r.fake.ksefRequests.count
        XCTAssertEqual(downloadsAfter, downloadsBefore)
    }

    func testALongRateLimitIsPartialAndResumable() async throws {
        let invoices = [fakeInvoice(1), fakeInvoice(2)]
        let limited = Locked(true)
        let second = invoices[1].metadata.ksefNumber
        let r = rig(invoices: invoices, downloadStatus: { number in
            limited.value && number == second ? FakeDownloadAnswer(status: 429, headers: ["Retry-After": "900"]) : nil
        })

        let first = await KsefCore.run(r.options)

        XCTAssertEqual(first.status, .partial)
        XCTAssertEqual(first.saved.count, 1)
        XCTAssertEqual(r.notifications.value.count, 1)
        XCTAssertEqual(r.notifications.value[0].title, "KSeF: pobrano częściowo (1)")
        XCTAssertTrue(try text(reportURL(r.dataDir)).contains("Status: częściowe — Limit zapytań KSeF — trzeba odczekać 900 s."))
        XCTAssertFalse(exists(r.dataDir.appendingPathComponent("state.json")))

        limited.value = false
        let again = await KsefCore.run(r.options)

        XCTAssertEqual(again.status, .complete)
        XCTAssertEqual(again.saved.count, 1)
        XCTAssertEqual(try indexLines(r.dataDir).count, 2)
        XCTAssertEqual(try state(r.dataDir), ["checkpoint": HWM] as NSDictionary)
    }

    func testAnAuthenticationFailureNotifiesWithTheReason() async throws {
        let r = rig(authStatus: FakeAuthStatus(
            code: 460, description: "Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu", details: ["Certyfikat odwołany"]
        ))

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(r.notifications.value.count, 1)
        XCTAssertEqual(r.notifications.value[0].title, "KSeF: błąd pobierania faktur")
        XCTAssertTrue(r.notifications.value[0].message.hasPrefix("Uwierzytelnienie w KSeF nieudane (kod 460"))
        XCTAssertTrue(try text(reportURL(r.dataDir)).contains("BŁĄD — "))
    }

    func testAWrongKeyPasswordFailsBeforeAnyRequest() async {
        let r = rig(keyPassword: "wrong")

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertTrue(summary.reason?.hasPrefix("Nie można odczytać klucza prywatnego") ?? false)
        let requests = await r.fake.requests.count
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(r.notifications.value.count, 1)
    }

    func testAnOfflineMacFailsAfterRetries() async {
        let r = rig(fetchError: URLError(.notConnectedToInternet))

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertTrue(summary.reason?.hasPrefix("Brak połączenia z KSeF: ") ?? false)
        XCTAssertEqual(r.clock.sleeps, [30_000, 30_000, 30_000])
        XCTAssertEqual(r.notifications.value.count, 1)
        XCTAssertEqual(r.notifications.value[0].message, summary.reason)
    }

    func testAFailureAfterSomeInvoicesWereSavedMentionsThem() async throws {
        let invoices = [fakeInvoice(1), fakeInvoice(2)]
        let second = invoices[1].metadata.ksefNumber
        let r = rig(invoices: invoices, downloadStatus: { $0 == second ? FakeDownloadAnswer(status: 500) : nil })

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.saved.count, 1)
        XCTAssertTrue(r.notifications.value[0].message.hasSuffix(" Zapisano wcześniej: 1."))
        XCTAssertTrue(try text(reportURL(r.dataDir)).contains("FV/1"))
    }

    func testADryRunWritesAndNotifiesNothing() async {
        let r = rig(invoices: [fakeInvoice(1), fakeInvoice(2)], dryRun: true)

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .complete)
        XCTAssertEqual(summary.saved.count, 0)
        XCTAssertFalse(exists(r.dataDir))
        XCTAssertFalse(exists(r.snapshotURL))
        XCTAssertEqual(r.notifications.value.count, 0)
        let downloads = await r.fake.ksefRequests
        XCTAssertEqual(downloads, [])
        XCTAssertEqual(r.logs.value.count, 1)
        XCTAssertTrue(r.logs.value[0].hasPrefix("dry run: 2 invoices"))
    }

    func testADryRunReportsTheCounts() async {
        let r = rig(invoices: [fakeInvoice(1), fakeInvoice(2)], dryRun: true)
        let summary = await KsefCore.run(r.options)
        XCTAssertEqual(summary.checked, DryRunCounts(listed: 2, notSaved: 2))
    }

    func testAFailedDryRunStaysQuiet() async {
        let r = rig(authStatus: FakeAuthStatus(code: 460, description: "Błąd certyfikatu"), dryRun: true)

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertTrue(summary.reason?.hasPrefix("Uwierzytelnienie w KSeF nieudane (kod 460") ?? false)
        XCTAssertFalse(exists(r.dataDir))
        XCTAssertFalse(exists(r.snapshotURL))
        XCTAssertEqual(r.notifications.value.count, 0)
        XCTAssertEqual(r.logs.value.count, 0)
    }

    func testWritesTheWidgetSnapshotAfterSavingInvoices() async throws {
        let r = rig(invoices: [fakeInvoice(1), fakeInvoice(2)])

        _ = await KsefCore.run(r.options)

        let written = try jsonObject(r.snapshotURL)
        XCTAssertEqual(written["status"] as? String, "complete")
        XCTAssertNil(written["reason"])
        XCTAssertEqual(written["today"] as? String, warsawDay(START))
        XCTAssertEqual(written["savedToday"] as? Int, 2)
        let invoices = try XCTUnwrap(written["invoices"] as? [[String: Any]])
        XCTAssertEqual(invoices.map { $0["invoiceNumber"] as? String }, ["FV/2", "FV/1"])
        XCTAssertEqual(invoices[0]["seller"] as? String, "Sprzedawca 2")
        XCTAssertEqual(invoices[0]["amount"] as? String, "200,50 PLN")
        XCTAssertTrue((invoices[0]["viewUrl"] as? String ?? "").hasPrefix("https://qr-test.ksef.mf.gov.pl/invoice/1111111111/20-11-2026/"))
    }

    func testAQuietRunStillWritesTheSnapshot() async throws {
        let r = rig(invoices: [fakeInvoice(1), fakeInvoice(2)])
        _ = await KsefCore.run(r.options)
        try FileManager.default.removeItem(at: r.snapshotURL)

        _ = await KsefCore.run(r.options)

        let written = try jsonObject(r.snapshotURL)
        XCTAssertEqual(written["status"] as? String, "complete")
        XCTAssertEqual((written["invoices"] as? [Any])?.count, 2)
    }

    func testAFailedRunRecordsTheFailureInTheSnapshot() async throws {
        let r = rig(authStatus: FakeAuthStatus(code: 460, description: "Błąd certyfikatu"))

        _ = await KsefCore.run(r.options)

        let written = try jsonObject(r.snapshotURL)
        XCTAssertEqual(written["status"] as? String, "failed")
        XCTAssertTrue((written["reason"] as? String ?? "").hasPrefix("Uwierzytelnienie w KSeF nieudane (kod 460"))
        XCTAssertEqual((written["invoices"] as? [Any])?.count, 0)
        XCTAssertEqual(written["savedToday"] as? Int, 0)
    }

    func testACorruptIndexStillGivesAFailedSnapshot() async throws {
        let r = rig()
        try FileManager.default.createDirectory(at: r.dataDir, withIntermediateDirectories: true)
        try Data("{\"ksefNumber\":".utf8).write(to: r.dataDir.appendingPathComponent("index.jsonl"))

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.reason, "Uszkodzony plik index.jsonl, linia 1")
        let written = try jsonObject(r.snapshotURL)
        XCTAssertEqual(written["status"] as? String, "failed")
        XCTAssertEqual(written["reason"] as? String, "Uszkodzony plik index.jsonl, linia 1")
        XCTAssertEqual((written["invoices"] as? [Any])?.count, 0)
        XCTAssertTrue(r.logs.value.contains { $0.contains("could not read the index for the widget") })
    }

    private func reportSections(_ dataDir: URL) throws -> Int {
        try text(reportURL(dataDir)).split(separator: "\n").filter { $0.hasPrefix("## Uruchomienie") }.count
    }

    func testTheSameFailureTwiceOnOneDayNotifiesOnceAndReportsTwice() async throws {
        let r = rig(fetchError: URLError(.notConnectedToInternet))

        _ = await KsefCore.run(r.options)
        _ = await KsefCore.run(r.options)

        XCTAssertEqual(r.notifications.value.count, 1)
        XCTAssertEqual(try reportSections(r.dataDir), 2)
        XCTAssertEqual(try jsonObject(r.snapshotURL)["status"] as? String, "failed")
        XCTAssertEqual(r.logs.value.filter { $0.contains("repeated failure, notification skipped") }.count, 1)
    }

    func testTheSameFailureOnTheNextWarsawDayNotifiesAgain() async {
        let r = rig(fetchError: URLError(.notConnectedToInternet))

        _ = await KsefCore.run(r.options)
        // 00:30 in Warsaw but still 2026-11-26 in UTC: the comparison must use the Warsaw day.
        var later = r.options
        later.now = { instant("2026-11-26T23:30:00Z") }
        _ = await KsefCore.run(later)

        XCTAssertEqual(r.notifications.value.count, 2)
    }

    private func failing(_ status: Int, _ body: String) -> Rig {
        rig(invoices: [fakeInvoice(1)], downloadStatus: { _ in FakeDownloadAnswer(status: status, body: body) })
    }

    private func sharing(_ snapshotURL: URL, _ r: Rig) -> RunOptions {
        var options = r.options
        options.snapshotURL = snapshotURL
        return options
    }

    func testTwo500ResponsesThatDifferOnlyInATimestampAndReferenceNotifyOnce() async throws {
        let first = failing(500, "{\"timestamp\":\"2026-11-26T07:00:01Z\",\"referenceNumber\":\"20261126-EE-AAAAAAAAAA-0000000001-01\"}")
        let second = failing(500, "{\"timestamp\":\"2026-11-26T08:00:03Z\",\"referenceNumber\":\"20261126-EE-BBBBBBBBBB-0000000002-02\"}")

        _ = await KsefCore.run(first.options)
        _ = await KsefCore.run(sharing(first.snapshotURL, second))

        XCTAssertEqual(first.notifications.value.count, 1)
        XCTAssertEqual(second.notifications.value.count, 0)
        let written = try jsonObject(first.snapshotURL)
        XCTAssertEqual(written["failureKey"] as? String, "KSeF 500")
        XCTAssertTrue((written["reason"] as? String ?? "").contains("BBBBBBBBBB"))
    }

    func testA500FollowedByA401NotifiesBothTimes() async throws {
        let first = failing(500, "x")
        let second = failing(401, "x")

        _ = await KsefCore.run(first.options)
        _ = await KsefCore.run(sharing(first.snapshotURL, second))

        XCTAssertEqual(first.notifications.value.count, 1)
        XCTAssertEqual(second.notifications.value.count, 1)
        XCTAssertEqual(try jsonObject(first.snapshotURL)["failureKey"] as? String, "KSeF 401")
    }

    func testAPreviousFailedSnapshotWithoutFailureKeyNotifies() async throws {
        let r = rig(fetchError: URLError(.notConnectedToInternet))
        let previous = "{\"status\":\"failed\",\"reason\":\"Brak połączenia z KSeF: fetch failed\",\"today\":\"\(warsawDay(START))\"}"
        try Data(previous.utf8).write(to: r.snapshotURL)

        _ = await KsefCore.run(r.options)

        XCTAssertEqual(r.notifications.value.count, 1)
    }

    func testADifferentReasonNotifies() async {
        let first = rig(fetchError: URLError(.notConnectedToInternet))
        let second = rig(fetchError: URLError(.timedOut))

        _ = await KsefCore.run(first.options)
        _ = await KsefCore.run(sharing(first.snapshotURL, second))

        XCTAssertEqual(first.notifications.value.count, 1)
        XCTAssertEqual(second.notifications.value.count, 1)
    }

    func testAFailureAfterACompleteRunNotifiesAgain() async {
        let first = rig(fetchError: URLError(.notConnectedToInternet))
        let complete = rig()
        let third = rig(fetchError: URLError(.notConnectedToInternet))

        _ = await KsefCore.run(first.options)
        _ = await KsefCore.run(sharing(first.snapshotURL, complete))
        _ = await KsefCore.run(sharing(first.snapshotURL, third))

        XCTAssertEqual(first.notifications.value.count, 1)
        XCTAssertEqual(third.notifications.value.count, 1)
    }

    func testAGarbledPreviousSnapshotNotifies() async throws {
        let r = rig(fetchError: URLError(.notConnectedToInternet))
        try Data("{\"status\":\"failed\"".utf8).write(to: r.snapshotURL)

        _ = await KsefCore.run(r.options)

        XCTAssertEqual(r.notifications.value.count, 1)
        XCTAssertEqual(try jsonObject(r.snapshotURL)["status"] as? String, "failed")
    }

    func testARepeatedFailureThatSavedNewInvoicesStillNotifies() async {
        let invoices = [fakeInvoice(1), fakeInvoice(2)]
        let second = invoices[1].metadata.ksefNumber
        func partlyFailing() -> Rig {
            rig(invoices: invoices, downloadStatus: { $0 == second ? FakeDownloadAnswer(status: 500) : nil })
        }
        let first = partlyFailing()
        let again = partlyFailing()

        _ = await KsefCore.run(first.options)
        _ = await KsefCore.run(sharing(first.snapshotURL, again))

        XCTAssertEqual(first.notifications.value.count, 1)
        XCTAssertEqual(again.notifications.value.count, 1)
        XCTAssertTrue(again.notifications.value[0].message.hasSuffix(" Zapisano wcześniej: 1."))
    }

    func testSurvivesAFailingNotifier() async {
        let r = rig(invoices: [fakeInvoice(1)], notify: { _, _ in throw KsefError("Powiadomienia są wyłączone") })

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .complete)
        XCTAssertTrue(r.logs.value.contains { $0.contains("Powiadomienia są wyłączone") })
    }

    private func writeIdentity(_ dataDir: URL, nip: String, environment: String) throws {
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data("{\"nip\":\"\(nip)\",\"environment\":\"\(environment)\"}\n".utf8).write(to: dataDir.appendingPathComponent("identity.json"))
    }

    private func mismatchMessage(nip: String, environment: String) -> String {
        "Folder faktur zawiera dane innego podatnika lub środowiska (NIP \(nip), \(environment)). Wybierz inny folder w Ustawieniach."
    }

    func testAFolderOfAnotherNipIsRefusedBeforeAnyRequest() async throws {
        let r = rig(invoices: [fakeInvoice(1)])
        try writeIdentity(r.dataDir, nip: "1111111111", environment: "test")

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.reason, mismatchMessage(nip: "1111111111", environment: "test"))
        let requests = await r.fake.requests.count
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(r.notifications.value.count, 1)
        XCTAssertTrue(try text(reportURL(r.dataDir)).contains("BŁĄD — Folder faktur zawiera dane innego podatnika"))
        XCTAssertEqual(try jsonObject(r.snapshotURL)["status"] as? String, "failed")
        XCTAssertFalse(exists(r.dataDir.appendingPathComponent("index.jsonl")))
        XCTAssertFalse(exists(r.dataDir.appendingPathComponent("state.json")))
    }

    func testAFolderOfAnotherEnvironmentIsRefused() async throws {
        let r = rig(invoices: [fakeInvoice(1)])
        try writeIdentity(r.dataDir, nip: "5265877635", environment: "prod")

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.reason, mismatchMessage(nip: "5265877635", environment: "prod"))
        XCTAssertEqual(summary.saved.count, 0)
    }

    func testAFolderWithoutAMarkerIsAdoptedAndKeepsItsCheckpoint() async throws {
        let r = rig(invoices: [fakeInvoice(1)])
        try FileManager.default.createDirectory(at: r.dataDir, withIntermediateDirectories: true)
        let written = "{\"checkpoint\":\"2026-11-26T05:00:00.0000000+00:00\"}\n"
        try Data(written.utf8).write(to: r.dataDir.appendingPathComponent("state.json"))

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .complete)
        XCTAssertEqual(
            try text(r.dataDir.appendingPathComponent("identity.json")), "{\"nip\":\"5265877635\",\"environment\":\"test\"}\n"
        )
        XCTAssertEqual(try state(r.dataDir), ["checkpoint": HWM] as NSDictionary)
    }

    func testAMatchingMarkerRunsNormally() async throws {
        let r = rig(invoices: [fakeInvoice(1)])
        try writeIdentity(r.dataDir, nip: "5265877635", environment: "test")

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .complete)
        XCTAssertEqual(summary.saved.count, 1)
    }

    func testADryRunOnAnotherIdentityFailsAndWritesNothing() async throws {
        let r = rig(invoices: [fakeInvoice(1)], dryRun: true)
        try writeIdentity(r.dataDir, nip: "5265877635", environment: "prod")

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.reason, mismatchMessage(nip: "5265877635", environment: "prod"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: r.dataDir.path), ["identity.json"])
        XCTAssertFalse(exists(r.snapshotURL))
        XCTAssertEqual(r.notifications.value.count, 0)
    }

    func testAdoptingAFolderWritesTheMarkerAndRefusesAnotherIdentity() throws {
        let dataDir = root.appendingPathComponent("adopted")
        let settings = Settings(nip: "5265877635", environment: .test, startDate: "2026-11-01", dataDir: dataDir.path, verified: true)

        try adoptDataFolder(settings)
        try adoptDataFolder(settings)

        XCTAssertEqual(
            try text(dataDir.appendingPathComponent("identity.json")), "{\"nip\":\"5265877635\",\"environment\":\"test\"}\n"
        )
        var other = settings
        other.environment = .prod
        XCTAssertThrowsError(try adoptDataFolder(other)) {
            XCTAssertEqual(errorMessage($0), mismatchMessage(nip: "5265877635", environment: "test"))
        }
    }

    private func ledgerLines(_ dataDir: URL) throws -> [String] {
        try text(dataDir.appendingPathComponent("ledger.jsonl")).split(separator: "\n").map(String.init)
    }

    private func yearSummary(_ snapshotURL: URL) throws -> NSDictionary? {
        try jsonObject(snapshotURL)["yearSummary"] as? NSDictionary
    }

    func testTheLedgerFollowsACompleteDownloadForBothSubjects() async throws {
        let r = rig(invoices: [fakeInvoice(1)], salesInvoices: [fakeInvoice(7)])

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .complete)
        XCTAssertEqual(try ledgerLines(r.dataDir), [
            "{\"ksefNumber\":\"5265877635-20261120-000001123456-AB\",\"subjectType\":\"Subject2\",\"issueDate\":\"2026-11-20\","
                + "\"invoiceType\":\"Vat\",\"currency\":\"PLN\",\"netAmount\":100,\"grossAmount\":100.5,\"vatAmount\":0.5}",
            "{\"ksefNumber\":\"5265877635-20261120-000007123456-AB\",\"subjectType\":\"Subject1\",\"issueDate\":\"2026-11-20\","
                + "\"invoiceType\":\"Vat\",\"currency\":\"PLN\",\"netAmount\":700,\"grossAmount\":700.5,\"vatAmount\":0.5}",
        ])
        XCTAssertEqual(
            try jsonObject(r.dataDir.appendingPathComponent("ledger-state.json")) as NSDictionary,
            ["Subject2": HWM, "Subject1": HWM, "completeAt": KsefTime.iso(r.clock.now)] as NSDictionary
        )
        XCTAssertEqual(
            try yearSummary(r.snapshotURL),
            ["text": "2026 · wydatki 100,00 PLN · przychody 700,00 PLN", "warning": false] as NSDictionary
        )
        XCTAssertEqual(r.logs.value.count, 1)
    }

    func testTheLedgerCostsOneQueryPerSubjectWhenIdle() async {
        let r = rig(invoices: [fakeInvoice(1)])

        _ = await KsefCore.run(r.options)
        let first = await metadataQueries(r)
        _ = await KsefCore.run(r.options)
        let second = await metadataQueries(r)

        XCTAssertEqual(first, 9)
        XCTAssertEqual(second, 12)
    }

    func testTheLedgerPausesBeforeEveryMetadataQueryItSends() async {
        let r = rig(invoices: [fakeInvoice(1)])

        _ = await KsefCore.run(r.options)
        let ledgerQueries = await metadataQueries(r) - 1
        let first = r.clock.sleeps.filter { $0 == 500 }.count
        _ = await KsefCore.run(r.options)
        let idleQueries = await metadataQueries(r) - 1 - ledgerQueries - 1

        XCTAssertEqual(ledgerQueries, 8)
        XCTAssertEqual(first, ledgerQueries)
        XCTAssertEqual(idleQueries, 2)
        XCTAssertEqual(r.clock.sleeps.filter { $0 == 500 }.count, ledgerQueries + idleQueries)
    }

    func testAPartialDownloadSkipsTheLedger() async throws {
        let invoices = [fakeInvoice(1), fakeInvoice(2)]
        let second = invoices[1].metadata.ksefNumber
        let r = rig(invoices: invoices, downloadStatus: { number in
            number == second ? FakeDownloadAnswer(status: 429, headers: ["Retry-After": "900"]) : nil
        })

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .partial)
        let queries = await metadataQueries(r)
        XCTAssertEqual(queries, 1)
        XCTAssertFalse(exists(r.dataDir.appendingPathComponent("ledger.jsonl")))
        XCTAssertEqual(try yearSummary(r.snapshotURL), ["text": "2026 · podsumowanie w przygotowaniu", "warning": true] as NSDictionary)
    }

    func testALedgerRateLimitLeavesTheRunCompleteAndSaysSoInTheFooter() async throws {
        let limited = Locked(true)
        let r = rig(invoices: [fakeInvoice(1)], metadataAnswer: { subject in
            limited.value && subject == "Subject1" ? FakeDownloadAnswer(status: 429, headers: ["Retry-After": "900"]) : nil
        })

        let first = await KsefCore.run(r.options)

        XCTAssertEqual(first.status, .complete)
        XCTAssertEqual(first.saved.count, 1)
        XCTAssertEqual(r.notifications.value.map(\.title), ["KSeF: 1 nowa faktura"])
        XCTAssertFalse(try text(reportURL(r.dataDir)).contains("ledger"))
        XCTAssertTrue(r.logs.value.contains("ledger Subject1 stopped: Limit zapytań KSeF — trzeba odczekać 900 s."))
        let ledgerState = try jsonObject(r.dataDir.appendingPathComponent("ledger-state.json"))
        XCTAssertNotNil(ledgerState["Subject2"])
        XCTAssertNil(ledgerState["completeAt"])
        XCTAssertEqual(try yearSummary(r.snapshotURL), ["text": "2026 · podsumowanie w przygotowaniu", "warning": true] as NSDictionary)

        limited.value = false
        _ = await KsefCore.run(r.options)

        XCTAssertEqual(
            try yearSummary(r.snapshotURL), ["text": "2026 · wydatki 100,00 PLN · przychody 0,00 PLN", "warning": false] as NSDictionary
        )

        limited.value = true
        let third = await KsefCore.run(r.options)

        XCTAssertEqual(third.status, .complete)
        let footer = try XCTUnwrap(yearSummary(r.snapshotURL))
        XCTAssertTrue((footer["text"] as? String ?? "").hasPrefix("2026 (stan na 26.11 08:0"))
        XCTAssertEqual(footer["warning"] as? Bool, true)
        XCTAssertEqual(r.notifications.value.count, 1)
    }

    private func unsummable(_ n: Int) -> FakeInvoice {
        var metadata = fakeInvoice(n).metadata
        metadata.netAmount = nil
        return FakeInvoice(metadata: metadata, xml: Data())
    }

    func testAnInvoiceTheLedgerCannotSumLeavesTheRunCompleteAndIsCounted() async throws {
        let baseline = rig(invoices: [fakeInvoice(1)], salesInvoices: [fakeInvoice(7)])
        let r = rig(invoices: [fakeInvoice(1)], salesInvoices: [fakeInvoice(7), unsummable(8)])
        _ = await KsefCore.run(baseline.options)

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .complete)
        XCTAssertEqual(summary.saved.count, 1)
        XCTAssertEqual(r.notifications.value.map(\.title), baseline.notifications.value.map(\.title))
        XCTAssertEqual(r.notifications.value.map(\.message), baseline.notifications.value.map(\.message))
        XCTAssertEqual(try text(reportURL(r.dataDir)), try text(reportURL(baseline.dataDir)))
        XCTAssertEqual(try ledgerLines(r.dataDir).count, 2)
        let skipped = "5265877635-20261120-000008123456-AB"
        let ledgerState = try jsonObject(r.dataDir.appendingPathComponent("ledger-state.json"))
        XCTAssertNotNil(ledgerState["completeAt"])
        XCTAssertEqual(
            ledgerState["skipped"] as? NSArray, [["subjectType": "Subject1", "ksefNumber": skipped]] as NSArray
        )
        XCTAssertEqual(
            try yearSummary(r.snapshotURL),
            ["text": "2026 · wydatki 100,00 PLN · przychody 700,00 PLN · pominięte: 1", "warning": true] as NSDictionary
        )
        let reason = "Nieprawidłowe metadane faktury \"\(skipped)\" do podsumowania roku"
        XCTAssertEqual(r.logs.value.filter { $0.hasPrefix("ledger") }, ["ledger Subject1 skipped \"\(skipped)\": \(reason)"])
    }

    func testNoSummaryFromAFolderOfAnotherIdentity() async throws {
        let r = rig(invoices: [fakeInvoice(1)])
        try writeIdentity(r.dataDir, nip: "1111111111", environment: "test")
        let ledgerFile = r.dataDir.appendingPathComponent("ledger.jsonl")
        let existing = Data("{\"ksefNumber\":\"x\"}\n".utf8)
        try existing.write(to: ledgerFile)

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .failed)
        XCTAssertNil(try jsonObject(r.snapshotURL)["yearSummary"])
        XCTAssertEqual(try Data(contentsOf: ledgerFile), existing)
    }

    func testAFailedLoginStillWritesTheSummaryFromDisk() async throws {
        let r = rig(authStatus: FakeAuthStatus(code: 460, description: "Błąd certyfikatu"))

        _ = await KsefCore.run(r.options)

        XCTAssertEqual(try yearSummary(r.snapshotURL), ["text": "2026 · podsumowanie w przygotowaniu", "warning": true] as NSDictionary)
    }

    func testADryRunNeverTouchesTheLedger() async {
        let r = rig(invoices: [fakeInvoice(1)], dryRun: true)

        _ = await KsefCore.run(r.options)

        let queries = await metadataQueries(r)
        XCTAssertEqual(queries, 1)
        XCTAssertFalse(exists(r.dataDir.appendingPathComponent("ledger.jsonl")))
        XCTAssertFalse(exists(r.dataDir.appendingPathComponent("ledger-state.json")))
    }

    func testAnExistingFolderKeepsItsFilesAndGainsTheLedger() async throws {
        let r = rig(salesInvoices: [fakeInvoice(7)])
        try writeIdentity(r.dataDir, nip: "5265877635", environment: "test")
        let identity = r.dataDir.appendingPathComponent("identity.json")
        let index = r.dataDir.appendingPathComponent("index.jsonl")
        try Data((try FormatsFixture.load().indexLines.joined(separator: "\n") + "\n").utf8).write(to: index)
        try Data("{\"checkpoint\":\"2026-11-26T05:00:00.0000000+00:00\"}\n".utf8).write(to: r.dataDir.appendingPathComponent("state.json"))
        let identityBefore = try Data(contentsOf: identity)
        let indexBefore = try Data(contentsOf: index)

        let summary = await KsefCore.run(r.options)

        XCTAssertEqual(summary.status, .complete)
        XCTAssertEqual(try Data(contentsOf: identity), identityBefore)
        XCTAssertEqual(try Data(contentsOf: index), indexBefore)
        XCTAssertEqual(try text(r.dataDir.appendingPathComponent("state.json")), "{\"checkpoint\":\"\(HWM)\"}\n")
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: r.dataDir.path)),
            ["identity.json", "index.jsonl", "ledger-state.json", "ledger.jsonl", "state.json"]
        )
    }

    private let setupMessage = "Brak hasła klucza w Pęku kluczy (usługa local.ksef-daily-fetch.KsefWidget, konto key-password)"

    func testSetupFailureNotifiesAndWritesAFailedSnapshot() async throws {
        let url = try temporaryDirectory().appendingPathComponent("widget.json")
        let notifications = Locked<[(title: String, message: String)]>([])

        await reportSetupFailure(
            setupMessage, snapshotURL: url, now: START,
            notify: { title, message in notifications.update { $0.append((title, message)) } }, log: { _ in }
        )

        XCTAssertEqual(notifications.value.count, 1)
        XCTAssertEqual(notifications.value[0].title, "KSeF: błąd pobierania faktur")
        XCTAssertEqual(notifications.value[0].message, setupMessage)
        let written = try jsonObject(url)
        XCTAssertEqual(written["status"] as? String, "failed")
        XCTAssertEqual(written["reason"] as? String, setupMessage)
        XCTAssertEqual(written["failureKey"] as? String, setupMessage)
        XCTAssertEqual((written["invoices"] as? [Any])?.count, 0)
    }

    func testARepeatedSetupFailureNotifiesOnce() async throws {
        let url = try temporaryDirectory().appendingPathComponent("widget.json")
        let notifications = Locked<[(title: String, message: String)]>([])
        let logs = Locked<[String]>([])

        for _ in 0..<2 {
            await reportSetupFailure(
                setupMessage, snapshotURL: url, now: START,
                notify: { title, message in notifications.update { $0.append((title, message)) } },
                log: { line in logs.update { $0.append(line) } }
            )
        }

        XCTAssertEqual(notifications.value.count, 1)
        XCTAssertTrue(logs.value.contains { $0.contains("repeated failure, notification skipped") })
    }
}
