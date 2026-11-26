import CryptoKit
import XCTest
@testable import KsefCore

private let NOW = instant("2026-11-26T08:00:00Z")
private let HWM = "2026-11-26T07:00:00.1234567+00:00"
private let defaultFrom = "2026-11-25T08:00:00.1234567+00:00"
private let fromAfterHwmBody = "{\"exception\":{\"exceptionCode\":21183}}"

private func sha256(_ bytes: Data) -> String {
    Data(SHA256.hash(data: bytes)).base64EncodedString()
}

private struct Fake {
    let metadata: InvoiceMetadata
    let xml: Data
}

private func makeInvoice(_ n: Int, ksefNumber: String? = nil, issueDate: String = "2026-11-20", hash: String? = nil) -> Fake {
    let xml = Data("<Faktura>\(n)</Faktura>".utf8)
    let hex = String(format: "%06X", n)
    let minute = String(format: "%02d", n % 60)
    return Fake(
        metadata: InvoiceMetadata(
            ksefNumber: ksefNumber ?? "5265877635-20261120-\(hex)123456-AB", invoiceNumber: "FV/\(n)", issueDate: issueDate,
            permanentStorageDate: "2026-11-20T09:\(minute):00.1234567+00:00", seller: Seller(nip: "1111111111", name: "Sprzedawca"),
            grossAmount: Double(100 + n), currency: "PLN", invoiceHash: hash ?? sha256(xml)
        ),
        xml: xml
    )
}

private func page(
    _ invoices: [InvoiceMetadata], hasMore: Bool = false, isTruncated: Bool = false, hwm: String? = HWM
) -> MetadataPage {
    MetadataPage(hasMore: hasMore, isTruncated: isTruncated, permanentStorageHwmDate: hwm, invoices: invoices)
}

private final class FakeSyncStore: SyncStore {
    private(set) var saves: [String] = []
    private(set) var checkpoints: [String] = []
    private var saved: Set<String>
    private var savedAt: [Int64]
    private let now: () -> Date

    init(alreadySaved: [String], now: @escaping () -> Date, earlierSaves: [Int64]) {
        saved = Set(alreadySaved)
        self.now = now
        savedAt = earlierSaves
    }

    func has(_ ksefNumber: String) -> Bool { saved.contains(ksefNumber) }

    func savedSince(_ instant: Date) -> Int {
        let threshold = KsefTime.millis(instant)
        return savedAt.filter { $0 > threshold }.count
    }

    func saveInvoice(_ invoice: InvoiceMetadata, xml: Data) throws {
        saves.append(invoice.ksefNumber)
        saved.insert(invoice.ksefNumber)
        savedAt.append(KsefTime.millis(now()))
    }

    func writeCheckpoint(_ value: String) throws { checkpoints.append(value) }
}

private final class Harness {
    let clock = FakeClock(NOW)
    let store: FakeSyncStore
    let downloads = Locked<[String]>([])
    let onSaved = Locked<[String]>([])
    let queries = Locked<[Window]>([])
    let deps: SyncDeps

    var saves: [String] { store.saves }
    var checkpoints: [String] { store.checkpoints }
    var sleeps: [Int] { clock.sleeps }

    init(
        query: @escaping Query, invoices: [Fake] = [], alreadySaved: [String] = [], earlierSaves: [Int64] = [],
        from: String = defaultFrom, tokenValidUntil: String? = nil,
        download: (@Sendable (String) async throws -> Data)? = nil
    ) {
        let clock = clock
        let store = FakeSyncStore(alreadySaved: alreadySaved, now: { clock.now }, earlierSaves: earlierSaves)
        self.store = store
        let xmlByNumber = Dictionary(uniqueKeysWithValues: invoices.map { ($0.metadata.ksefNumber, $0.xml) })
        let downloads = downloads
        let onSaved = onSaved
        let queries = queries
        deps = SyncDeps(
            from: from,
            store: store,
            query: { window, offset in
                queries.update { $0.append(window) }
                return try await query(window, offset)
            },
            download: { number in
                downloads.update { $0.append(number) }
                if let download { return try await download(number) }
                guard let xml = xmlByNumber[number] else { throw KsefError("no xml for \(number)") }
                return xml
            },
            tokenValidUntil: tokenValidUntil ?? KsefTime.iso(millis: KsefTime.millis(NOW) + 15 * 60_000),
            now: { clock.now },
            sleep: { clock.sleep($0) },
            onSaved: { invoice in onSaved.update { $0.append(invoice.ksefNumber) } }
        )
    }
}

private func minutesAgo(_ minutes: Double, count: Int) -> [Int64] {
    Array(repeating: KsefTime.millis(NOW) - Int64((minutes * 60_000).rounded()), count: count)
}

final class SyncTests: XCTestCase {
    func testAcceptsARealLookingNumberAndRejectsPathTraversal() {
        XCTAssertNotNil("5265877635-20261126-0123456789AB-CD".wholeMatch(of: ksefNumberPattern))
        XCTAssertNil("../../etc/passwd".wholeMatch(of: ksefNumberPattern))
        XCTAssertNil("5265877635-20261126-0123456789AB-CD\n".wholeMatch(of: ksefNumberPattern))
        XCTAssertNil("٥265877635-20261126-0123456789AB-CD".wholeMatch(of: ksefNumberPattern))
    }

    func testClosesTheWindow90DaysAfterFromWhenThatIsInThePast() {
        XCTAssertEqual(
            nextWindow(from: "2026-01-01T00:00:00Z", now: NOW),
            Window(from: "2026-01-01T00:00:00Z", to: "2026-04-01T00:00:00.000Z")
        )
    }

    func testLeavesTheWindowOpenOtherwiseAndKeepsFromVerbatim() {
        XCTAssertEqual(
            nextWindow(from: "2026-11-01T00:00:00.1234567+00:00", now: NOW),
            Window(from: "2026-11-01T00:00:00.1234567+00:00", to: nil)
        )
    }

    func testParsesKSeF7DigitFractionsWithAnOffset() {
        XCTAssertEqual(
            nextWindow(from: "2026-01-01T00:00:00.1234567+00:00", now: NOW),
            Window(from: "2026-01-01T00:00:00.1234567+00:00", to: "2026-04-01T00:00:00.123Z")
        )
    }

    func testClosesTheWindowWithMillisecondTruncation() {
        XCTAssertEqual(
            nextWindow(from: "2026-01-01T00:00:00.9999999+00:00", now: NOW).to,
            "2026-04-01T00:00:00.999Z"
        )
    }

    private let window = Window(from: defaultFrom, to: nil)
    private let listed = [1, 2, 3].map { makeInvoice($0).metadata }

    func testPagesUntilHasMoreIsFalse() async throws {
        let calls = Locked<[(Window, Int)]>([])
        let pages = Locked([page(Array(listed[0...1]), hasMore: true, hwm: "first"), page([listed[2]], hwm: "last")])

        let result = try await listWindow({ window, offset in
            calls.update { $0.append((window, offset)) }
            return pages.update { $0.removeFirst() }
        }, window)

        XCTAssertEqual(calls.value.map(\.0), [window, window])
        XCTAssertEqual(calls.value.map(\.1), [0, 1])
        XCTAssertEqual(result.invoices, listed)
        XCTAssertEqual(result.hwm, "last")
    }

    func testNarrowsFromOnTruncationAndDedupes() async throws {
        let closed = Window(from: window.from, to: "2026-11-26T00:00:00.000Z")
        let calls = Locked<[(Window, Int)]>([])
        let pages = Locked([page(Array(listed[0...1]), hasMore: true, isTruncated: true), page(Array(listed[1...2]))])

        let result = try await listWindow({ window, offset in
            calls.update { $0.append((window, offset)) }
            return pages.update { $0.removeFirst() }
        }, closed)

        XCTAssertEqual(calls.value.map(\.0), [closed, Window(from: listed[1].permanentStorageDate, to: closed.to)])
        XCTAssertEqual(calls.value.map(\.1), [0, 0])
        XCTAssertEqual(result.invoices, listed)
    }

    func testTreats21183AsNothingSettledYet() async throws {
        let result = try await listWindow({ _, _ in
            throw KsefApiError(status: 400, method: "POST", path: "/invoices/query/metadata", body: fromAfterHwmBody)
        }, window)
        XCTAssertEqual(result.invoices, [])
        XCTAssertNil(result.hwm)

        do {
            _ = try await listWindow({ _, _ in
                throw KsefApiError(status: 400, method: "POST", path: "/invoices/query/metadata", body: "{\"exception\":{\"exceptionCode\":21111}}")
            }, window)
            XCTFail("expected KsefApiError")
        } catch is KsefApiError {
        }
    }

    func testReportsAMissingHWMAsNull() async throws {
        let first = listed[0]
        let result = try await listWindow({ _, _ in page([first], hwm: nil) }, window)
        XCTAssertNil(result.hwm)
    }

    func testATruncatedPageWithNoInvoicesFails() async {
        let message = await thrownMessage {
            try await listWindow({ _, _ in page([], hasMore: true, isTruncated: true) }, self.window)
        }
        XCTAssertEqual(message, "Nieprawidłowa odpowiedź KSeF na POST /invoices/query/metadata")
    }

    func testSavesNewInvoicesInOrderAndAdvancesTheCheckpointToTheHWM() async throws {
        let all = [1, 2, 3].map { makeInvoice($0) }
        let h = Harness(query: { _, _ in page(all.map(\.metadata)) }, invoices: all, alreadySaved: [all[1].metadata.ksefNumber])

        let outcome = try await syncInvoices(h.deps)

        let expected = [all[0].metadata.ksefNumber, all[2].metadata.ksefNumber]
        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(h.downloads.value, expected)
        XCTAssertEqual(h.saves, expected)
        XCTAssertEqual(h.onSaved.value, expected)
        XCTAssertEqual(h.checkpoints, [HWM])
    }

    private let hwm2 = "2026-11-26T07:30:00.7654321+00:00"
    private var hundredDaysAgo: String { KsefTime.iso(millis: KsefTime.millis(NOW) - 100 * 86_400_000) }

    func testWalksAClosedWindowThenTheOpenOne() async throws {
        let from = hundredDaysAgo
        let hwm2 = hwm2
        let h = Harness(query: { window, _ in page([], hwm: window.to ?? hwm2) }, from: from)

        let outcome = try await syncInvoices(h.deps)

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(h.queries.value.count, 2)
        let first = h.queries.value[0]
        XCTAssertEqual(first.from, from)
        let to = try XCTUnwrap(first.to)
        XCTAssertEqual(h.queries.value[1], Window(from: to, to: nil))
        XCTAssertEqual(h.checkpoints, [to, hwm2])
    }

    func testAClosedWindowWithAnHWMPastItsEndSettlesUpToItsEndAndContinues() async throws {
        let hwm2 = hwm2
        let h = Harness(query: { window, _ in
            page([], hwm: window.to.map { KsefTime.iso(millis: KsefTime.millis($0)! + 86_400_000) } ?? hwm2)
        }, from: hundredDaysAgo)

        let outcome = try await syncInvoices(h.deps)

        XCTAssertEqual(outcome, .complete)
        let to = try XCTUnwrap(h.queries.value[0].to)
        XCTAssertEqual(h.queries.value[1], Window(from: to, to: nil))
        XCTAssertEqual(h.checkpoints, [to, hwm2])
    }

    func testStopsWhenTheHWMDidNotMovePastFrom() async throws {
        let h = Harness(query: { _, _ in page([], hwm: defaultFrom) })
        let outcome = try await syncInvoices(h.deps)
        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(h.queries.value.count, 1)
    }

    func testARateLimitMidWindowIsPartialAndKeepsTheCheckpoint() async throws {
        let all = [1, 2].map { makeInvoice($0) }
        let second = all[1].metadata.ksefNumber
        let firstXml = all[0].xml
        let h = Harness(query: { _, _ in page(all.map(\.metadata)) }, invoices: all, download: { number in
            if number == second { throw RateLimitError(retryAfterSeconds: 600) }
            return firstXml
        })

        let outcome = try await syncInvoices(h.deps)

        XCTAssertEqual(outcome, .partial("Limit zapytań KSeF — trzeba odczekać 600 s."))
        XCTAssertEqual(h.saves, [all[0].metadata.ksefNumber])
        XCTAssertEqual(h.checkpoints, [])
    }

    func testARateLimitWhileListingIsPartialToo() async throws {
        let h = Harness(query: { _, _ in throw RateLimitError(retryAfterSeconds: 900) })
        let outcome = try await syncInvoices(h.deps)
        XCTAssertEqual(outcome, .partial("Limit zapytań KSeF — trzeba odczekać 900 s."))
    }

    func testStopsAtTheHourlyDownloadCap() async throws {
        let all = (1...(maxDownloadsPerHour + 1)).map { makeInvoice($0) }
        let h = Harness(query: { _, _ in page(all.map(\.metadata)) }, invoices: all)

        let outcome = try await syncInvoices(h.deps)

        XCTAssertEqual(outcome, .partial("Limit 60 pobrań na godzinę."))
        XCTAssertEqual(h.saves.count, 60)
        XCTAssertEqual(h.checkpoints, [])
    }

    func test60SavesFrom30MinutesAgoStopTheRunBeforeAnyDownload() async throws {
        let a = makeInvoice(1)
        let h = Harness(query: { _, _ in page([a.metadata]) }, invoices: [a], earlierSaves: minutesAgo(30, count: 60))

        let outcome = try await syncInvoices(h.deps)

        XCTAssertEqual(outcome, .partial("Limit 60 pobrań na godzinę."))
        XCTAssertEqual(h.downloads.value, [])
        XCTAssertEqual(h.checkpoints, [])
    }

    func test60SavesFrom61MinutesAgoDoNot() async throws {
        let a = makeInvoice(1)
        let h = Harness(query: { _, _ in page([a.metadata]) }, invoices: [a], earlierSaves: minutesAgo(61, count: 60))

        let outcome = try await syncInvoices(h.deps)

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(h.downloads.value, [a.metadata.ksefNumber])
    }

    func test59RecentSavesLeaveRoomForExactlyOneDownload() async throws {
        let all = [1, 2].map { makeInvoice($0) }
        let h = Harness(query: { _, _ in page(all.map(\.metadata)) }, invoices: all, earlierSaves: minutesAgo(30, count: 59))

        let outcome = try await syncInvoices(h.deps)

        XCTAssertEqual(outcome, .partial("Limit 60 pobrań na godzinę."))
        XCTAssertEqual(h.downloads.value, [all[0].metadata.ksefNumber])
        XCTAssertEqual(h.checkpoints, [])
    }

    func testSavesThatAgeOutDuringTheRunFreeUpRoom() async throws {
        let all = [1, 2].map { makeInvoice($0) }
        // 58 saves leave the window 1.8 s into the run, i.e. during the pause before the second download.
        let earlierSaves = minutesAgo(59.97, count: 58) + minutesAgo(10, count: 1)
        let h = Harness(query: { _, _ in page(all.map(\.metadata)) }, invoices: all, earlierSaves: earlierSaves)

        let outcome = try await syncInvoices(h.deps)

        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(h.downloads.value.count, 2)
    }

    func testPacesDownloads() async throws {
        let all = [1, 2, 3].map { makeInvoice($0) }
        let h = Harness(query: { _, _ in page(all.map(\.metadata)) }, invoices: all)
        _ = try await syncInvoices(h.deps)
        XCTAssertEqual(h.sleeps, [4000, 4000])
    }

    func testATokenAboutToExpireEndsTheRun() async throws {
        let a = makeInvoice(1)
        let h = Harness(
            query: { _, _ in page([a.metadata]) }, invoices: [a],
            tokenValidUntil: KsefTime.iso(millis: KsefTime.millis(NOW) + 30_000)
        )

        let outcome = try await syncInvoices(h.deps)

        XCTAssertEqual(outcome, .partial("Token dostępu wkrótce wygaśnie."))
        XCTAssertEqual(h.downloads.value, [])
        XCTAssertEqual(h.checkpoints, [])
    }

    func testFailsOnAHashMismatch() async {
        let a = makeInvoice(1, hash: sha256(Data("other".utf8)))
        let h = Harness(query: { _, _ in page([a.metadata]) }, invoices: [a])

        let message = await thrownMessage { try await syncInvoices(h.deps) }

        XCTAssertEqual(message, "Skrót pobranej faktury \(a.metadata.ksefNumber) nie zgadza się z metadanymi KSeF")
        XCTAssertEqual(h.saves, [])
    }

    func testRejectsAHostileKsefNumberBeforeDownload() async {
        let a = makeInvoice(1, ksefNumber: "../../etc/passwd")
        let h = Harness(query: { _, _ in page([a.metadata]) }, invoices: [a])

        let message = await thrownMessage { try await syncInvoices(h.deps) }

        XCTAssertEqual(message, "Nieprawidłowy numer KSeF w odpowiedzi API: \"../../etc/passwd\"")
        XCTAssertEqual(h.downloads.value, [])
        XCTAssertEqual(h.saves, [])
        XCTAssertEqual(h.checkpoints, [])
    }

    func testRejectsAHostileIssueDateBeforeDownload() async {
        let a = makeInvoice(1, issueDate: "../../x")
        let h = Harness(query: { _, _ in page([a.metadata]) }, invoices: [a])

        let message = await thrownMessage { try await syncInvoices(h.deps) }

        XCTAssertEqual(message, "Nieprawidłowa data wystawienia w odpowiedzi API: \"../../x\"")
        XCTAssertEqual(h.downloads.value, [])
        XCTAssertEqual(h.saves, [])
    }

    func testKeepsTheCheckpointOnANullHWMOfTheOpenWindow() async throws {
        let h = Harness(query: { _, _ in page([], hwm: nil) })
        let outcome = try await syncInvoices(h.deps)
        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(h.checkpoints, [])
    }

    func testAClosedWindowMustReportAnHWM() async {
        let h = Harness(query: { _, _ in page([], hwm: nil) }, from: hundredDaysAgo)

        let message = await thrownMessage { try await syncInvoices(h.deps) }

        let window = h.queries.value[0]
        XCTAssertEqual(message, "Nieoczekiwany permanentStorageHwmDate (null) dla okna \(window.from) – \(window.to!)")
        XCTAssertEqual(h.checkpoints, [])
    }
}
