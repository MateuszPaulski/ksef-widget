import XCTest
@testable import KsefCore

final class ReportTests: XCTestCase {
    private let nbsp = "\u{00A0}"
    private let startedAt = instant("2026-11-26T07:00:12Z")  // 08:00:12 in Warsaw (CET)
    private let invoiceHash = "UtQp9Gpc51y+u3xApZjIjgkpZ01js+J8KflSPW8WzIE="
    private let link = "https://qr.ksef.mf.gov.pl/invoice/1111111111/01-02-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE"

    private func invoice(number: String = "FV/1/2026", name: String? = "Acme Sp. z o.o.", amount: Double = 12345.67) -> InvoiceMetadata {
        InvoiceMetadata(
            ksefNumber: "1111111111-20260201-0123456789AB-CD", invoiceNumber: number, issueDate: "2026-02-01",
            permanentStorageDate: "2026-02-01T09:00:00.1234567+00:00", seller: Seller(nip: "1111111111", name: name),
            grossAmount: amount, currency: "PLN", invoiceHash: invoiceHash
        )
    }

    private func summary(_ status: RunStatus, reason: String? = nil, saved: [InvoiceMetadata] = []) -> RunSummary {
        RunSummary(startedAt: startedAt, status: status, reason: reason, failureKey: nil, saved: saved, checked: nil)
    }

    private func many(_ n: Int) -> [InvoiceMetadata] {
        (0..<n).map { invoice(name: "Sprzedawca \($0 + 1)", amount: Double(10 + $0)) }
    }

    func testFormatsWithPolishGroupingAndTwoDecimals() {
        XCTAssertEqual(formatAmount(12345.67, "PLN"), "12\(nbsp)345,67 PLN")
        XCTAssertEqual(formatAmount(53.63, "EUR"), "53,63 EUR")
        XCTAssertEqual(formatAmount(10, "PLN"), "10,00 PLN")
    }

    func testBuildsTheKODILinkWithABase64URLHash() {
        let invoice = invoice()
        func url(_ environment: KsefEnvironment) -> String {
            invoiceViewUrl(environment, sellerNip: invoice.seller.nip, issueDate: invoice.issueDate, invoiceHash: invoice.invoiceHash)
        }
        XCTAssertEqual(url(.prod), link)
        XCTAssertTrue(url(.test).hasPrefix("https://qr-test.ksef.mf.gov.pl/invoice/"))
    }

    func testInflectsLikePolish() {
        XCTAssertEqual(invoiceCountLabel(1), "1 nowa faktura")
        for n in [2, 3, 4, 22, 104] { XCTAssertEqual(invoiceCountLabel(n), "\(n) nowe faktury") }
        for n in [5, 11, 12, 13, 14, 21, 112] { XCTAssertEqual(invoiceCountLabel(n), "\(n) nowych faktur") }
    }

    func testEscapesMarkdownCharactersAndCollapsesNewlines() {
        XCTAssertEqual(escapeMarkdown("\\ ` * _ [ ] < > # |"), "\\\\ \\` \\* \\_ \\[ \\] \\< \\> \\# \\|")
        XCTAssertEqual(escapeMarkdown("a\r\n\nb\rc"), "a b c")
        XCTAssertEqual(escapeMarkdown("a\u{2028}b"), "a\u{2028}b")
    }

    func testNeutralisesBareUrlAutolinksWithoutTouchingOtherText() {
        XCTAssertEqual(escapeMarkdown("https://evil.example"), "https\\://evil.example")
        XCTAssertEqual(escapeMarkdown("www.evil.example"), "www\\.evil.example")
        XCTAssertEqual(escapeMarkdown("WwW.x www.www.y"), "WwW\\.x www\\.www\\.y")
        XCTAssertEqual(escapeMarkdown("Acme Sp. z o.o. a:b a/b 12.50"), "Acme Sp. z o.o. a:b a/b 12.50")
        // Combining marks must not hide a pattern from the scalar-level match.
        XCTAssertEqual(escapeMarkdown("://\u{301}"), "\\://\u{301}")
    }

    func testPercentEncodesTheSellerNipAsOnePathSegment() {
        let url = invoiceViewUrl(.prod, sellerNip: "1/2 (3)!*'ł-._~", issueDate: "2026-02-01", invoiceHash: invoiceHash)
        XCTAssertTrue(url.hasPrefix("https://qr.ksef.mf.gov.pl/invoice/1%2F2%20%283%29%21%2A%27%C5%82-._~/01-02-2026/"), url)
    }

    func testUsesTheEuropeWarsawCalendarDay() {
        XCTAssertEqual(warsawDay(instant("2026-11-26T23:30:00Z")), "2026-11-27")
        XCTAssertEqual(warsawDay(instant("2026-07-01T21:59:00Z")), "2026-07-01")
        XCTAssertEqual(warsawDay(instant("2026-07-01T22:00:00Z")), "2026-07-02")
    }

    func testListsSavedInvoices() {
        let report = formatReportSection(summary(.complete, saved: [invoice(), invoice(number: "FV/2", name: nil)]), .prod)
        let ksefNumber = "`1111111111-20260201-0123456789AB-CD`"
        XCTAssertEqual(report, [
            "## Uruchomienie 08:00:12",
            "",
            "Status: zakończone",
            "Nowe faktury: 2",
            "",
            "- **Acme Sp. z o.o.** (NIP 1111111111) — nr FV/1/2026, 12\(nbsp)345,67 PLN, wystawiona 01.02.2026 — [podgląd w KSeF](\(link)) — \(ksefNumber)",
            "- **NIP 1111111111** (NIP 1111111111) — nr FV/2, 12\(nbsp)345,67 PLN, wystawiona 01.02.2026 — [podgląd w KSeF](\(link)) — \(ksefNumber)",
        ].joined(separator: "\n"))
    }

    func testOmitsTheListWhenNothingWasSavedAndShowsPartialAndFailedReasons() {
        XCTAssertEqual(
            formatReportSection(summary(.partial, reason: "Limit 60 pobrań na godzinę."), .prod),
            "## Uruchomienie 08:00:12\n\nStatus: częściowe — Limit 60 pobrań na godzinę.\nNowe faktury: 0"
        )
        XCTAssertEqual(
            formatReportSection(summary(.failed, reason: "Brak połączenia z KSeF: fetch failed"), .prod),
            "## Uruchomienie 08:00:12\n\nStatus: BŁĄD — Brak połączenia z KSeF: fetch failed\nNowe faktury: 0"
        )
    }

    func testEscapesAHostileSellerOntoASingleLine() {
        let hostile = invoice(number: "FV|1\n# x", name: "Evil*Corp [x](http://e) | # <b>\nline2")
        let section = formatReportSection(summary(.complete, saved: [hostile]), .prod)
        let lines = section.split(separator: "\n", omittingEmptySubsequences: false)
        let bullets = lines.filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets.count, 1)
        XCTAssertTrue(bullets[0].contains("Evil\\*Corp \\[x\\](http\\://e) \\| \\# \\<b\\> line2"))
        XCTAssertTrue(bullets[0].contains("nr FV\\|1 \\# x"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("# ") })
    }

    func testBreaksBareUrlsInASellerNameAndEscapesTheNipAndCurrency() {
        let hostile = InvoiceMetadata(
            ksefNumber: "1111111111-20260201-0123456789AB-CD", invoiceNumber: "FV/1/2026", issueDate: "2026-02-01",
            permanentStorageDate: "2026-02-01T09:00:00.1234567+00:00",
            seller: Seller(nip: "1*2", name: "https://evil.example www.evil.example"),
            grossAmount: 12345.67, currency: "P_N", invoiceHash: invoiceHash
        )

        let section = formatReportSection(summary(.complete, saved: [hostile]), .prod)

        let bullet = section.split(separator: "\n").first { $0.hasPrefix("- ") }.map(String.init) ?? ""
        XCTAssertTrue(bullet.hasPrefix("- **https\\://evil.example www\\.evil.example** (NIP 1\\*2) — nr FV/1/2026, 12"), bullet)
        XCTAssertTrue(bullet.contains(" P\\_N, wystawiona"), bullet)
        XCTAssertTrue(bullet.contains("/invoice/1%2A2/01-02-2026/"), bullet)
    }

    func testIsNilForACompleteRunWithNothingNew() {
        XCTAssertNil(formatNotification(summary(.complete)))
    }

    func testSummarisesNewInvoices() {
        let two = formatNotification(summary(.complete, saved: many(2)))
        XCTAssertEqual(two?.title, "KSeF: 2 nowe faktury")
        XCTAssertEqual(two?.message, "Sprzedawca 1: 10,00 PLN; Sprzedawca 2: 11,00 PLN")
        let five = formatNotification(summary(.complete, saved: many(5)))
        XCTAssertEqual(five?.title, "KSeF: 5 nowych faktur")
        XCTAssertEqual(five?.message, "Sprzedawca 1: 10,00 PLN; Sprzedawca 2: 11,00 PLN; Sprzedawca 3: 12,00 PLN; i 2 więcej")
    }

    func testFallsBackToTheNIPWhenTheSellerHasNoName() {
        let notification = formatNotification(summary(.complete, saved: [invoice(name: "")]))
        XCTAssertEqual(notification?.title, "KSeF: 1 nowa faktura")
        XCTAssertEqual(notification?.message, "NIP 1111111111: 12\(nbsp)345,67 PLN")
    }

    func testDescribesAPartialRun() {
        let notification = formatNotification(summary(.partial, reason: "Limit 60 pobrań na godzinę.", saved: many(1)))
        XCTAssertEqual(notification?.title, "KSeF: pobrano częściowo (1)")
        XCTAssertEqual(notification?.message, "Limit 60 pobrań na godzinę. Reszta przy następnym uruchomieniu.")
    }

    func testDescribesAFailedRun() {
        let plain = formatNotification(summary(.failed, reason: "Brak połączenia z KSeF: x"))
        XCTAssertEqual(plain?.title, "KSeF: błąd pobierania faktur")
        XCTAssertEqual(plain?.message, "Brak połączenia z KSeF: x")
        XCTAssertEqual(formatNotification(summary(.failed, reason: "Błąd.", saved: many(2)))?.message, "Błąd. Zapisano wcześniej: 2.")
    }

    func testTruncatesAFailedMessageTo240Characters() throws {
        let message = try XCTUnwrap(formatNotification(summary(.failed, reason: String(repeating: "x", count: 500)))?.message)
        XCTAssertEqual(message.count, 240)
        XCTAssertTrue(message.hasSuffix("…"))
    }

    func testMatchesTheTypeScriptGoldenFormats() throws {
        let golden = try FormatsFixture.load()
        for amount in golden.amounts {
            XCTAssertEqual(formatAmount(amount.value, "PLN"), amount.text, "\(amount.value)")
        }

        let now = instant(golden.now)
        let invoices = golden.invoices
        func summary(_ status: RunStatus, _ reason: String?, _ saved: ArraySlice<InvoiceMetadata>) -> RunSummary {
            RunSummary(startedAt: now, status: status, reason: reason, failureKey: nil, saved: Array(saved), checked: nil)
        }

        let notifications = [
            summary(.complete, nil, invoices[...]),
            summary(.partial, "Limit 60 pobrań na godzinę.", invoices[..<1]),
            summary(.failed, String(repeating: "x", count: 300), invoices[..<2]),
        ].compactMap(formatNotification)
        XCTAssertEqual(notifications.map { FormatsFixture.Notification(title: $0.title, message: $0.message) }, golden.notifications)

        let first = formatReportSection(summary(.complete, nil, invoices[...]), .prod)
        let second = formatReportSection(summary(.failed, "Brak połączenia z KSeF: fetch failed", invoices[..<1]), .test)
        XCTAssertEqual("# Faktury z KSeF — 2026-11-26\n\n\(first)\n\(second)\n", golden.reportFile)
    }
}
