import XCTest
@testable import KsefCore

private let nbsp = "\u{a0}"
private let NOW = instant("2026-11-26T13:00:00Z")

final class YearSummaryTests: XCTestCase {
    private var counter = 0

    private func entry(
        _ subject: Subject, _ issueDate: String, _ type: String = "Vat", net: Double, currency: String = "PLN"
    ) -> LedgerEntry {
        counter += 1
        return LedgerEntry(
            ksefNumber: "K\(counter)", subjectType: subject, issueDate: issueDate, invoiceType: type, currency: currency,
            netAmount: net, grossAmount: net, vatAmount: 0
        )
    }

    private func folder(_ entries: [LedgerEntry], completeAt: String? = "2026-11-26T10:00:00.000Z") throws -> URL {
        let dir = try temporaryDirectory()
        let ledger = try Ledger.open(dataDir: dir)
        for entry in entries { try ledger.add(entry) }
        try ledger.writeCheckpoint(.buyer, "2026-11-26T09:00:00.0000000+00:00")
        try ledger.writeCheckpoint(.seller, "2026-11-26T09:00:00.0000000+00:00")
        if let completeAt { try ledger.writeCompleteAt(instant(completeAt)) }
        return dir
    }

    private func yearsLines() -> [LedgerEntry] {
        [
            entry(.buyer, "2026-11-20", net: 43.6), entry(.buyer, "2026-11-21", "Kor", net: -10), entry(.buyer, "2025-12-30", net: 999),
            entry(.seller, "2026-10-01", net: 182_400), entry(.seller, "2026-10-02", net: 1200, currency: "EUR"),
        ]
    }

    func testFormatsTotals() {
        XCTAssertEqual(formatTotals([:]), "0,00 PLN")
        XCTAssertEqual(formatTotals(["PLN": 4_821_055]), "48\(nbsp)210,55 PLN")
        XCTAssertEqual(
            formatTotals(["EUR": 120_000, "PLN": 18_240_000, "USD": 0, "CHF": -500]),
            "182\(nbsp)400,00 PLN + \(formatAmount(-5, "CHF")) + 1200,00 EUR"
        )
        XCTAssertEqual(formatTotals(["EUR": 1]), "0,00 PLN + 0,01 EUR")
    }

    func testTheLineWhenTheLedgerIsCurrent() throws {
        let line = yearSummary(dataDir: try folder(yearsLines()), ledgerCompleted: true, now: NOW)

        XCTAssertEqual(
            line,
            YearSummaryLine(text: "2026 · wydatki 33,60 PLN · przychody 182\(nbsp)400,00 PLN + 1200,00 EUR", warning: false)
        )
    }

    func testBehindShowsStanNaRightAfterTheYear() throws {
        let line = yearSummary(dataDir: try folder(yearsLines()), ledgerCompleted: false, now: NOW)

        XCTAssertEqual(
            line,
            YearSummaryLine(
                text: "2026 (stan na 26.11 11:00) · wydatki 33,60 PLN · przychody 182\(nbsp)400,00 PLN + 1200,00 EUR", warning: true
            )
        )
    }

    func testNeverCompletedShowsNoTotal() throws {
        let expected = YearSummaryLine(text: "2026 · podsumowanie w przygotowaniu", warning: true)

        XCTAssertEqual(yearSummary(dataDir: try folder(yearsLines(), completeAt: nil), ledgerCompleted: false, now: NOW), expected)
        XCTAssertEqual(yearSummary(dataDir: try temporaryDirectory(), ledgerCompleted: false, now: NOW), expected)
    }

    func testAnUnreadableLedgerSaysSo() throws {
        let dir = try folder(yearsLines())
        let url = dir.appendingPathComponent("ledger.jsonl")
        var lines = try text(url).split(separator: "\n").map(String.init)
        lines[2] = "{\"ksefNumber\":"
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)

        XCTAssertEqual(
            yearSummary(dataDir: dir, ledgerCompleted: true, now: NOW),
            YearSummaryLine(text: "2026 · podsumowanie niedostępne: Uszkodzony plik ledger.jsonl, linia 3", warning: true)
        )

        let unsummable = try folder([entry(.buyer, "2026-11-20", net: 1.005)])
        XCTAssertEqual(
            yearSummary(dataDir: unsummable, ledgerCompleted: true, now: NOW),
            YearSummaryLine(text: "2026 · podsumowanie niedostępne: Uszkodzony plik ledger.jsonl", warning: true)
        )
    }

    func testSumsTheWarsawYearByIssueDate() throws {
        let dir = try folder([entry(.buyer, "2026-12-31", net: 7), entry(.buyer, "2027-01-01", net: 5)])

        let line = yearSummary(dataDir: dir, ledgerCompleted: true, now: instant("2026-12-31T23:30:00Z"))

        XCTAssertEqual(line, YearSummaryLine(text: "2027 · wydatki 5,00 PLN · przychody 0,00 PLN", warning: false))
    }
}
