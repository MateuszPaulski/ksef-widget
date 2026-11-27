import CryptoKit
import Foundation

private let maxWindowDays: Int64 = 90
let maxDownloadsPerHour = 60
private let hourMillis: Int64 = 3_600_000
private let minDownloadIntervalMs = 4_000
private let tokenMarginMs: Int64 = 60_000
// KSeF error code: `from` is later than the HWM, i.e. nothing has been settled yet.
private let fromAfterHwmCode = "21183"
private let quotedValueCharacters = 60

// Both patterns guard values that become part of a path, so digits are ASCII only.
nonisolated(unsafe) let ksefNumberPattern =
    /([1-9]([0-9][1-9]|[1-9][0-9])[0-9]{7})-(20[2-9][0-9]|2[1-9][0-9]{2}|[3-9][0-9]{3})(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])-([0-9A-F]{6})-?([0-9A-F]{6})-([0-9A-F]{2})/
nonisolated(unsafe) private let issueDatePattern = /[0-9]{4}-[0-9]{2}-[0-9]{2}/

typealias Query = @Sendable (Window, Int) async throws -> MetadataPage

func nextWindow(from: String, now: Date) -> Window {
    // An unparseable `from` leaves the window open, as NaN does in JavaScript.
    guard let start = KsefTime.millis(from) else { return Window(from: from, to: nil) }
    let to = start + maxWindowDays * 86_400_000
    return to < KsefTime.millis(now) ? Window(from: from, to: KsefTime.iso(millis: to)) : Window(from: from, to: nil)
}

func listWindow(_ query: Query, _ window: Window) async throws -> (invoices: [InvoiceMetadata], hwm: String?) {
    var invoices: [InvoiceMetadata] = []
    var seen = Set<String>()
    var from = window.from
    var pageOffset = 0
    while true {
        let page: MetadataPage
        do {
            page = try await query(Window(from: from, to: window.to), pageOffset)
        } catch let error as KsefApiError where error.status == 400 && error.body.contains(fromAfterHwmCode) {
            return ([], nil)
        }
        for invoice in page.invoices where seen.insert(invoice.ksefNumber).inserted { invoices.append(invoice) }
        if !page.hasMore { return (invoices, page.permanentStorageHwmDate) }
        if page.isTruncated {
            guard let last = page.invoices.last else { throw KsefError("Nieprawidłowa odpowiedź KSeF na POST /invoices/query/metadata") }
            from = last.permanentStorageDate
            pageOffset = 0
        } else {
            pageOffset += 1
        }
    }
}

protocol SyncStore: AnyObject {
    func has(_ ksefNumber: String) -> Bool
    func savedSince(_ instant: Date) -> Int
    func saveInvoice(_ invoice: InvoiceMetadata, xml: Data) throws
    func writeCheckpoint(_ value: String) throws
}

extension Store: SyncStore {}

struct SyncDeps {
    let from: String
    let store: SyncStore
    let query: Query
    let download: @Sendable (String) async throws -> Data
    let tokenValidUntil: String
    let now: @Sendable () -> Date
    let sleep: @Sendable (Int) async -> Void  // milliseconds
    let onSaved: (InvoiceMetadata) -> Void
}

enum SyncOutcome: Equatable {
    case complete
    case partial(String)
}

func quoted(_ value: String) -> String {
    String(JSONValue.string(value).compact().prefix(quotedValueCharacters))
}

/// Lists windows from `from`; `process` sees each window's invoices before its checkpoint is written,
/// and a non-nil result ends the walk without writing it.
func walkWindows(
    from start: String, query: Query, now: @Sendable () -> Date,
    process: ([InvoiceMetadata]) async throws -> SyncOutcome?,
    writeCheckpoint: (String) throws -> Void
) async throws -> SyncOutcome {
    var from = start
    do {
        while true {
            let window = nextWindow(from: from, now: now())
            let (invoices, hwm) = try await listWindow(query, window)
            if let outcome = try await process(invoices) { return outcome }

            // A closed window (backfill) must report an HWM; an open one may not have one yet.
            if let to = window.to, hwm == nil {
                throw KsefError("Nieoczekiwany permanentStorageHwmDate (null) dla okna \(window.from) – \(to)")
            }
            guard let hwm else { return .complete }
            // Everything up to a closed window's `to` is settled even if KSeF reports a later HWM.
            var next = hwm
            if let to = window.to, let hwmMillis = KsefTime.millis(hwm), let toMillis = KsefTime.millis(to), hwmMillis > toMillis {
                next = to
            }
            try writeCheckpoint(next)
            if window.to == nil || next == from { return .complete }
            from = next
        }
    } catch let error as RateLimitError {
        return .partial(errorMessage(error))
    }
}

func syncInvoices(_ deps: SyncDeps) async throws -> SyncOutcome {
    let store = deps.store
    var lastDownloadAt: Int64?

    return try await walkWindows(
        from: deps.from, query: deps.query, now: deps.now,
        process: { invoices in
            for invoice in invoices {
                if store.has(invoice.ksefNumber) { continue }
                guard invoice.ksefNumber.wholeMatch(of: ksefNumberPattern) != nil else {
                    throw KsefError("Nieprawidłowy numer KSeF w odpowiedzi API: \(quoted(invoice.ksefNumber))")
                }
                guard invoice.issueDate.wholeMatch(of: issueDatePattern) != nil else {
                    throw KsefError("Nieprawidłowa data wystawienia w odpowiedzi API: \(quoted(invoice.issueDate))")
                }
                if let validUntil = KsefTime.millis(deps.tokenValidUntil),
                   validUntil - KsefTime.millis(deps.now()) < tokenMarginMs {
                    return .partial("Token dostępu wkrótce wygaśnie.")
                }
                if let last = lastDownloadAt {
                    let wait = Int64(minDownloadIntervalMs) - (KsefTime.millis(deps.now()) - last)
                    if wait > 0 { await deps.sleep(Int(wait)) }
                }
                // Counted after the pause, against the current time: KSeF's limit is a rolling hour across runs.
                if store.savedSince(deps.now().addingTimeInterval(-Double(hourMillis) / 1000)) >= maxDownloadsPerHour {
                    return .partial("Limit \(maxDownloadsPerHour) pobrań na godzinę.")
                }
                lastDownloadAt = KsefTime.millis(deps.now())
                let bytes = try await deps.download(invoice.ksefNumber)
                guard Data(SHA256.hash(data: bytes)).base64EncodedString() == invoice.invoiceHash else {
                    throw KsefError("Skrót pobranej faktury \(invoice.ksefNumber) nie zgadza się z metadanymi KSeF")
                }
                try store.saveInvoice(invoice, xml: bytes)
                deps.onSaved(invoice)
            }
            return nil
        },
        writeCheckpoint: store.writeCheckpoint
    )
}
