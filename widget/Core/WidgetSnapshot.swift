import Foundation

let snapshotInvoices = 8

struct WidgetInvoice: Equatable {
    let ksefNumber: String
    let seller: String
    let invoiceNumber: String
    let amount: String
    let issueDate: String
    let savedAt: String
    let viewUrl: String
}

struct WidgetSnapshot: Equatable {
    let updatedAt: String
    let status: RunStatus
    let reason: String?
    let failureKey: String?
    let today: String
    let savedToday: Int
    let invoices: [WidgetInvoice]
    let yearSummary: YearSummaryLine?
}

func widgetInvoice(_ entry: IndexEntry, _ environment: KsefEnvironment) -> WidgetInvoice {
    WidgetInvoice(
        ksefNumber: entry.ksefNumber,
        seller: sellerLabel(Seller(nip: entry.sellerNip, name: entry.sellerName)),
        invoiceNumber: entry.invoiceNumber,
        amount: formatAmount(entry.grossAmount, entry.currency),
        issueDate: entry.issueDate,
        savedAt: entry.savedAt,
        viewUrl: invoiceViewUrl(environment, sellerNip: entry.sellerNip, issueDate: entry.issueDate, invoiceHash: entry.invoiceHash)
    )
}

/// `invoices` are in index order, oldest first.
func buildSnapshot(
    status: RunStatus, reason: String?, failureKey: String?, invoices: [WidgetInvoice], now: Date, yearSummary: YearSummaryLine? = nil
) -> WidgetSnapshot {
    let today = warsawDay(now)
    let savedToday = invoices.filter { invoice in
        KsefTime.millis(invoice.savedAt).map { warsawDay(KsefTime.date(millis: $0)) == today } ?? false
    }.count
    return WidgetSnapshot(
        updatedAt: KsefTime.iso(now), status: status, reason: reason, failureKey: failureKey, today: today,
        savedToday: savedToday, invoices: Array(invoices.suffix(snapshotInvoices).reversed()), yearSummary: yearSummary
    )
}

extension WidgetSnapshot {
    fileprivate var json: JSONValue {
        var fields: [(String, JSONValue)] = [("updatedAt", .string(updatedAt)), ("status", .string(status.rawValue))]
        if let reason { fields.append(("reason", .string(reason))) }
        if let failureKey { fields.append(("failureKey", .string(failureKey))) }
        fields.append(("today", .string(today)))
        fields.append(("savedToday", .number(Double(savedToday))))
        fields.append(("invoices", .array(invoices.map { invoice in
            .object([
                ("ksefNumber", .string(invoice.ksefNumber)),
                ("seller", .string(invoice.seller)),
                ("invoiceNumber", .string(invoice.invoiceNumber)),
                ("amount", .string(invoice.amount)),
                ("issueDate", .string(invoice.issueDate)),
                ("savedAt", .string(invoice.savedAt)),
                ("viewUrl", .string(invoice.viewUrl)),
            ])
        })))
        if let yearSummary {
            fields.append(("yearSummary", .object([("text", .string(yearSummary.text)), ("warning", .bool(yearSummary.warning))])))
        }
        return .object(fields)
    }
}

func writeSnapshot(_ snapshot: WidgetSnapshot, to url: URL) throws {
    try writeAtomic(Data((snapshot.json.pretty() + "\n").utf8), to: url)
}

func readSnapshotObject(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// A missing, unreadable or malformed file, or one without a `failureKey`, counts as "no previous failure".
func readPreviousFailure(_ url: URL) -> (failureKey: String, today: String)? {
    guard let object = readSnapshotObject(url),
          object["status"] as? String == "failed",
          let failureKey = object["failureKey"] as? String,
          let today = object["today"] as? String
    else { return nil }
    return (failureKey, today)
}
