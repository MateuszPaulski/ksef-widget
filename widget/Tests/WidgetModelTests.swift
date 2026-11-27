import XCTest

final class WidgetModelTests: XCTestCase {
    private let now = Fixtures.now

    private func make(_ snapshot: Snapshot, now: Date? = nil) -> WidgetModel {
        WidgetModel.make(.success(snapshot), now: now ?? self.now)
    }

    private func banner(_ text: String, _ tone: WidgetModel.Tone) -> WidgetModel.Banner {
        WidgetModel.Banner(text: text, tone: tone)
    }

    func testNormalSnapshot() {
        let model = make(Fixtures.snapshot())
        XCTAssertEqual(model.title, "KSeF · zaktualizowano 14:00")
        XCTAssertEqual(model.newToday, "2 nowe dziś")
        XCTAssertNil(model.banner)
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(
            model.rows[0],
            WidgetModel.Row(
                id: "K1", seller: "Acme Sp. z o.o.", amount: "1230,00 PLN", date: "26.11",
                url: URL(string: "https://qr.ksef.mf.gov.pl/invoice/1111111111/26-11-2026/hash1")
            )
        )
        XCTAssertNil(model.emptyText)
    }

    func testPluralTable() {
        XCTAssertEqual(newTodayLabel(1), "1 nowa dziś")
        for n in [2, 3, 4, 22, 104] { XCTAssertEqual(newTodayLabel(n), "\(n) nowe dziś") }
        for n in [5, 11, 12, 13, 14, 21, 112] { XCTAssertEqual(newTodayLabel(n), "\(n) nowych dziś") }
    }

    func testNoCountWhenZeroOrNotToday() {
        XCTAssertNil(make(Fixtures.snapshot(savedToday: 0)).newToday)
        XCTAssertNil(make(Fixtures.snapshot(today: "2026-11-25")).newToday)
        XCTAssertNil(make(Fixtures.snapshot(), now: Fixtures.midnight).newToday)
    }

    func testStaleFromThreeHours() {
        let snapshot = Fixtures.snapshot()
        let threshold = Fixtures.updatedAt.addingTimeInterval(WidgetModel.staleAfter)
        XCTAssertNil(make(snapshot, now: threshold.addingTimeInterval(-1)).banner)
        XCTAssertEqual(
            make(snapshot, now: threshold).banner,
            banner("Dane nieaktualne — ostatnia aktualizacja 26.11 14:00", .error)
        )
    }

    func testFailed() {
        let model = make(Fixtures.snapshot(status: .failed, reason: "Brak połączenia z KSeF: fetch failed"))
        XCTAssertEqual(model.banner, banner("Błąd pobierania: Brak połączenia z KSeF: fetch failed", .error))
        XCTAssertEqual(model.rows.count, 3)
    }

    func testPartial() {
        let model = make(Fixtures.snapshot(status: .partial, reason: "Limit 60 pobrań na godzinę."))
        XCTAssertEqual(model.banner, banner("Pobrano częściowo — reszta przy następnym uruchomieniu.", .warning))
    }

    func testStaleBeatsFailed() {
        let snapshot = Fixtures.snapshot(status: .failed, reason: "x")
        let model = make(snapshot, now: Fixtures.updatedAt.addingTimeInterval(4 * 3600))
        XCTAssertEqual(model.banner, banner("Dane nieaktualne — ostatnia aktualizacja 26.11 14:00", .error))
    }

    func testMissing() {
        let model = WidgetModel.make(.failure(.missing), now: now)
        XCTAssertEqual(model.title, "KSeF")
        XCTAssertNil(model.newToday)
        XCTAssertEqual(model.banner, banner("Brak danych — pobieranie jeszcze nie zapisało stanu widżetu.", .error))
        XCTAssertEqual(model.rows, [])
        XCTAssertNil(model.emptyText)
    }

    func testUnreadable() {
        let model = WidgetModel.make(.failure(.unreadable("x")), now: now)
        XCTAssertEqual(model.banner, banner("Nie można odczytać danych widżetu: x", .error))
    }

    func testEmptyList() {
        let model = make(Fixtures.snapshot(invoiceCount: 0))
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.emptyText, "Brak zapisanych faktur.")
    }

    func testFailedEmptyListHasNoEmptyText() {
        let model = make(Fixtures.snapshot(status: .failed, reason: "Uszkodzony plik index.jsonl, linia 1", invoiceCount: 0))
        XCTAssertNil(model.emptyText)
        XCTAssertEqual(model.banner, banner("Błąd pobierania: Uszkodzony plik index.jsonl, linia 1", .error))
    }

    func testHostileSellerStaysVerbatim() {
        let model = make(Fixtures.snapshot(invoiceCount: 8))
        XCTAssertEqual(model.rows[3].seller, "**Evil** [x](https://e.example)\nline2")
    }

    func testDisallowedURLHasNoLink() {
        let good = Fixtures.snapshot()
        let first = good.invoices[0]
        let hostile = Snapshot.Invoice(
            ksefNumber: first.ksefNumber, seller: first.seller, amount: first.amount,
            issueDate: first.issueDate, viewUrl: "https://evil.example/x"
        )
        let snapshot = Snapshot(
            updatedAt: good.updatedAt, status: good.status, reason: good.reason, today: good.today,
            savedToday: good.savedToday, invoices: [hostile] + good.invoices.dropFirst()
        )
        XCTAssertNil(make(snapshot).rows[0].url)
    }

    func testRowLimit() {
        XCTAssertEqual(make(Fixtures.snapshot()).rowLimit(isLarge: true), 8)
        XCTAssertEqual(make(Fixtures.snapshot()).rowLimit(isLarge: false), 3)
        XCTAssertEqual(make(Fixtures.snapshot(status: .partial)).rowLimit(isLarge: false), 2)
    }

    func testFooterCopiesTheSummary() {
        let text = "2026 (stan na 26.11 11:00) · wydatki 43,60 PLN · przychody 0,00 PLN"
        let summary = Snapshot.YearSummary(text: text, warning: true)
        let footer = WidgetModel.Footer(text: text, warning: true)
        XCTAssertEqual(make(Fixtures.snapshot(yearSummary: summary)).footer, footer)
        XCTAssertEqual(make(Fixtures.snapshot(status: .failed, reason: "x", yearSummary: summary)).footer, footer)
        let stale = make(Fixtures.snapshot(yearSummary: summary), now: Fixtures.updatedAt.addingTimeInterval(4 * 3600))
        XCTAssertEqual(stale.footer, footer)
        XCTAssertNil(WidgetModel.make(.failure(.missing), now: now).footer)
    }

    func testRowLimitWithAFooter() {
        let summary = Snapshot.YearSummary(text: "2026 · wydatki 0,00 PLN · przychody 0,00 PLN", warning: false)
        XCTAssertEqual(make(Fixtures.snapshot(yearSummary: summary)).rowLimit(isLarge: false), 2)
        XCTAssertEqual(make(Fixtures.snapshot(status: .partial, yearSummary: summary)).rowLimit(isLarge: false), 1)
        XCTAssertEqual(make(Fixtures.snapshot(yearSummary: summary)).rowLimit(isLarge: true), 8)
    }

    func testHostileFooterStaysVerbatim() {
        let summary = Snapshot.YearSummary(text: "**x** [y](https://e.example)", warning: false)
        XCTAssertEqual(make(Fixtures.snapshot(yearSummary: summary)).footer?.text, "**x** [y](https://e.example)")
    }

    func testTimelineDates() {
        let stale = Fixtures.updatedAt.addingTimeInterval(WidgetModel.staleAfter)
        XCTAssertEqual(WidgetModel.timelineDates(.success(Fixtures.snapshot()), now: now), [now, stale, Fixtures.midnight])
        XCTAssertEqual(WidgetModel.timelineDates(.failure(.missing), now: now), [now, Fixtures.midnight])
        let late = Fixtures.updatedAt.addingTimeInterval(4 * 3600)
        XCTAssertEqual(WidgetModel.timelineDates(.success(Fixtures.snapshot()), now: late), [late, Fixtures.midnight])
    }
}
