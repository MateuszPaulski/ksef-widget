import Foundation

enum Fixtures {
    // 2026-11-26T13:00:41.123Z, 14:00 in Warsaw.
    static let updatedAt = Date(timeIntervalSince1970: 1795698041.123)
    // 2026-11-26T13:20:00Z.
    static let now = Date(timeIntervalSince1970: 1795699200)
    // 2026-11-26T23:00:00Z, Warsaw midnight.
    static let midnight = Date(timeIntervalSince1970: 1795734000)

    static let contractJSON = """
    {
      "updatedAt": "2026-11-26T13:00:41.123Z",
      "status": "complete",
      "today": "2026-11-26",
      "savedToday": 2,
      "invoices": [
        {
          "ksefNumber": "5265877635-20261126-0123456789AB-CD",
          "seller": "Acme Sp. z o.o.",
          "invoiceNumber": "FV/2/2026",
          "amount": "1230,00 PLN",
          "issueDate": "2026-11-26",
          "savedAt": "2026-11-26T13:00:39.000Z",
          "viewUrl": "https://qr.ksef.mf.gov.pl/invoice/1111111111/26-11-2026/UtQp9Gpc51y-u3xApZjIjgkpZ01js-J8KflSPW8WzIE"
        }
      ]
    }
    """

    private static let rows: [(seller: String, amount: String, issueDate: String)] = [
        ("Acme Sp. z o.o.", "1230,00 PLN", "2026-11-26"),
        ("Orange Polska", "89,99 PLN", "2026-11-25"),
        ("Hetzner Online", "153,75 EUR", "2026-11-24"),
        ("**Evil** [x](https://e.example)\nline2", "12 345,67 PLN", "2026-11-23"),
        ("Bardzo Długa Nazwa Sprzedawcy Spółka z ograniczoną odpowiedzialnością Oddział w Polsce", "1,00 PLN", "2026-11-22"),
        ("NIP 1111111111", "99,00 USD", "2026-11-21"),
        ("Sprzedawca 7", "10,00 PLN", "2026-11-20"),
        ("Sprzedawca 8", "10,00 PLN", "2026-11-19"),
    ]

    static func snapshot(
        status: Snapshot.Status = .complete,
        reason: String? = nil,
        invoiceCount: Int = 3,
        today: String = "2026-11-26",
        savedToday: Int = 2,
        updatedAt: Date = Fixtures.updatedAt,
        yearSummary: Snapshot.YearSummary? = nil
    ) -> Snapshot {
        let invoices = rows.prefix(invoiceCount).enumerated().map { index, row in
            let day = row.issueDate.split(separator: "-").reversed().joined(separator: "-")
            return Snapshot.Invoice(
                ksefNumber: "K\(index + 1)",
                seller: row.seller,
                amount: row.amount,
                issueDate: row.issueDate,
                viewUrl: "https://qr.ksef.mf.gov.pl/invoice/1111111111/\(day)/hash\(index + 1)"
            )
        }
        return Snapshot(updatedAt: updatedAt, status: status, reason: reason, today: today, savedToday: savedToday, invoices: invoices, yearSummary: yearSummary)
    }
}
