import Foundation

struct YearSummaryLine: Equatable {
    let text: String
    let warning: Bool
}

func warsawYear(_ date: Date) -> Int {
    Int(warsawDay(date).prefix(4))!
}

/// PLN always, then every other currency with a non-zero sum, codes ascending.
func formatTotals(_ grosze: [String: Int64]) -> String {
    var text = formatAmount(Double(grosze["PLN", default: 0]) / 100, "PLN")
    for (currency, sum) in grosze.sorted(by: { $0.key < $1.key }) where currency != "PLN" && sum != 0 {
        text += " + " + formatAmount(Double(sum) / 100, currency)
    }
    return text
}

/// For the Warsaw year of `now`; `ledgerCompleted` = this run brought both subjects up to date.
func yearSummary(dataDir: URL, ledgerCompleted: Bool, now: Date) -> YearSummaryLine {
    let year = warsawYear(now)
    let ledger: Ledger
    do {
        ledger = try Ledger.open(dataDir: dataDir)
    } catch {
        return YearSummaryLine(text: "\(year) · podsumowanie niedostępne: \(errorMessage(error))", warning: true)
    }
    // A completion time from an earlier year says nothing about this year's totals; a run that just completed has a fresh one.
    let yearBegins = KsefTime.millis(yearStart(year)) ?? .min
    guard let completedAt = ledger.completeAt.flatMap(KsefTime.millis), ledgerCompleted || completedAt >= yearBegins else {
        return YearSummaryLine(text: "\(year) · podsumowanie w przygotowaniu", warning: true)
    }

    var totals: [Subject: [String: Int64]] = [:]
    for entry in ledger.entries where entry.issueDate.hasPrefix("\(year)-") {
        guard let net = grosze(entry.netAmount) else {
            return YearSummaryLine(text: "\(year) · podsumowanie niedostępne: Uszkodzony plik ledger.jsonl", warning: true)
        }
        totals[entry.subjectType, default: [:]][entry.currency, default: 0] += net
    }
    let state = ledgerCompleted ? "" : " (stan na \(warsawStamp(KsefTime.date(millis: completedAt))))"
    var text = "\(year) netto\(state) · wydatki \(formatTotals(totals[.buyer] ?? [:])) · przychody \(formatTotals(totals[.seller] ?? [:]))"
    let skipped = ledger.skipped.filter { $0.ksefNumber.split(separator: "-").dropFirst().first?.hasPrefix("\(year)") == true }.count
    if skipped > 0 { text += " · pominięte: \(skipped)" }
    return YearSummaryLine(text: text, warning: !ledgerCompleted || skipped > 0)
}
