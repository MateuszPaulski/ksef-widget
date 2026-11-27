import Foundation

private let notificationMaxCharacters = 240
private let notificationListedInvoices = 3

public enum RunStatus: String, Codable, Sendable {
    case complete, partial, failed
}

struct DryRunCounts: Equatable, Sendable {
    let listed: Int
    let notSaved: Int
}

public struct RunSummary: Sendable {
    let startedAt: Date
    public let status: RunStatus
    let reason: String?
    /// Stable identity of a failure for "same failure again" checks; `reason` is display text and may be volatile.
    let failureKey: String?
    public let saved: [InvoiceMetadata]
    let checked: DryRunCounts?
}

func formatAmount(_ amount: Double, _ currency: String) -> String {
    // Without the rounding rule ICU rounds half-even, which differs from Intl.NumberFormat.
    let style = FloatingPointFormatStyle<Double>.number
        .locale(Locale(identifier: "pl_PL"))
        .precision(.fractionLength(2))
        .rounded(rule: .toNearestOrAwayFromZero)
    return amount.formatted(style) + " " + currency
}

private func reverseDate(_ issueDate: String, separator: String) -> String {
    issueDate.split(separator: "-", omittingEmptySubsequences: false).reversed().joined(separator: separator)
}

/// Everything outside the RFC 3986 unreserved set, byte by byte, so links match those already in the owner's reports (pinned by formats.json).
private func encodePathSegment(_ text: String) -> String {
    text.utf8.map { byte in
        let isUnreserved = (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 95, 126].contains(byte)
        return isUnreserved ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }.joined()
}

func invoiceViewUrl(_ environment: KsefEnvironment, sellerNip: String, issueDate: String, invoiceHash: String) -> String {
    var hash = invoiceHash.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    while hash.hasSuffix("=") { hash.removeLast() }
    return "\(environment.qrBase)/invoice/\(encodePathSegment(sellerNip))/\(reverseDate(issueDate, separator: "-"))/\(hash)"
}

func invoiceCountLabel(_ n: Int) -> String {
    if n == 1 { return "1 nowa faktura" }
    let lastTwo = n % 100
    let isFew = n % 10 >= 2 && n % 10 <= 4 && (lastTwo < 12 || lastTwo > 14)
    return isFew ? "\(n) nowe faktury" : "\(n) nowych faktur"
}

/// Scalar-level on purpose: "\r\n" is one Character, U+2028 must stay as it is, and a combining mark after "/" must not
/// hide a pattern. The last step stops a bare URL in a seller name from becoming a clickable link.
func escapeMarkdown(_ text: String) -> String {
    var escaped: [Unicode.Scalar] = []
    var inLineBreak = false
    for scalar in text.unicodeScalars {
        if scalar == "\r" || scalar == "\n" {
            if !inLineBreak { escaped.append(" ") }
            inLineBreak = true
            continue
        }
        inLineBreak = false
        if "\\`*_[]<>#|".unicodeScalars.contains(scalar) { escaped.append("\\") }
        escaped.append(scalar)
    }

    let schemeSeparator: [Unicode.Scalar] = [":", "/", "/"]
    let www: [Unicode.Scalar] = ["w", "w", "w", "."]
    var result = String.UnicodeScalarView()
    var index = 0
    while index < escaped.count {
        let rest = escaped[index...]
        if rest.starts(with: schemeSeparator) {
            result.append("\\")
            result.append(contentsOf: schemeSeparator)
            index += schemeSeparator.count
        } else if rest.count >= www.count, rest.prefix(www.count).map(asciiLowercased) == www {
            result.append(contentsOf: rest.prefix(www.count - 1))
            result.append("\\")
            result.append(".")
            index += www.count
        } else {
            result.append(escaped[index])
            index += 1
        }
    }
    return String(result)
}

private func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
}

private let warsawCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    return calendar
}()

private func warsawComponents(_ date: Date) -> DateComponents {
    warsawCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
}

func warsawDay(_ date: Date) -> String {
    let c = warsawComponents(date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

func warsawTime(_ date: Date) -> String {
    let c = warsawComponents(date)
    return String(format: "%02d:%02d:%02d", c.hour!, c.minute!, c.second!)
}

func sellerLabel(_ seller: Seller) -> String {
    if let name = seller.name, !name.isEmpty { return name }
    return "NIP \(seller.nip)"
}

func formatReportSection(_ summary: RunSummary, _ environment: KsefEnvironment) -> String {
    let reason = escapeMarkdown(summary.reason ?? "")
    let status = switch summary.status {
    case .complete: "zakończone"
    case .partial: "częściowe — \(reason)"
    case .failed: "BŁĄD — \(reason)"
    }
    var lines = [
        "## Uruchomienie \(warsawTime(summary.startedAt))",
        "",
        "Status: \(status)",
        "Nowe faktury: \(summary.saved.count)",
    ]
    if !summary.saved.isEmpty { lines.append("") }
    for invoice in summary.saved {
        let url = invoiceViewUrl(
            environment, sellerNip: invoice.seller.nip, issueDate: invoice.issueDate, invoiceHash: invoice.invoiceHash
        )
        lines.append(
            "- **\(escapeMarkdown(sellerLabel(invoice.seller)))** (NIP \(escapeMarkdown(invoice.seller.nip)))"
                + " — nr \(escapeMarkdown(invoice.invoiceNumber)), \(formatAmount(invoice.grossAmount, escapeMarkdown(invoice.currency)))"
                + ", wystawiona \(reverseDate(invoice.issueDate, separator: "."))"
                + " — [podgląd w KSeF](\(url)) — `\(invoice.ksefNumber)`"
        )
    }
    return lines.joined(separator: "\n")
}

func formatNotification(_ summary: RunSummary) -> (title: String, message: String)? {
    let n = summary.saved.count
    let reason = summary.reason ?? ""
    switch summary.status {
    case .partial:
        return ("KSeF: pobrano częściowo (\(n))", "\(reason) Reszta przy następnym uruchomieniu.")
    case .failed:
        let message = reason + (n > 0 ? " Zapisano wcześniej: \(n)." : "")
        let clipped = message.count > notificationMaxCharacters
            ? String(message.prefix(notificationMaxCharacters - 1)) + "…"
            : message
        return ("KSeF: błąd pobierania faktur", clipped)
    case .complete:
        if n == 0 { return nil }
        var listed = summary.saved.prefix(notificationListedInvoices).map {
            "\(sellerLabel($0.seller)): \(formatAmount($0.grossAmount, $0.currency))"
        }
        if n > notificationListedInvoices { listed.append("i \(n - notificationListedInvoices) więcej") }
        return ("KSeF: \(invoiceCountLabel(n))", listed.joined(separator: "; "))
    }
}
