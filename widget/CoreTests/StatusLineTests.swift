import XCTest
@testable import KsefCore

final class StatusLineTests: XCTestCase {
    // 13:00 UTC is 14:00 in Warsaw in November.
    private let at = instant("2026-11-26T13:00:00Z")

    private func idle(_ status: RunStatus, reason: String? = nil) -> String {
        menuStatusLine(.idle(SnapshotStatus(updatedAt: at, status: status, reason: reason)))
    }

    func testFixedLines() {
        XCTAssertEqual(menuStatusLine(.running), "Pobieranie w toku…")
        XCTAssertEqual(menuStatusLine(.legacyAgent), "Wstrzymane: zainstalowane jest stare zadanie launchd")
        XCTAssertEqual(menuStatusLine(.notConfigured), "Nie skonfigurowano — otwórz Ustawienia…")
        XCTAssertEqual(menuStatusLine(.notVerified), "Sprawdź połączenie w Ustawieniach, aby zacząć pobieranie")
        XCTAssertEqual(menuStatusLine(.idle(nil)), "Jeszcze nie pobierano")
    }

    func testLastRunLines() {
        XCTAssertEqual(idle(.complete), "Ostatnio 26.11 14:00 — zakończone")
        XCTAssertEqual(idle(.partial, reason: "Limit 60 pobrań na godzinę."), "Ostatnio 26.11 14:00 — pobrano częściowo")
        XCTAssertEqual(idle(.failed, reason: "Brak połączenia z KSeF"), "Ostatnio 26.11 14:00 — błąd: Brak połączenia z KSeF")
    }

    func testTheTimeIsShownInWarsawSummerTime() {
        let summer = SnapshotStatus(updatedAt: instant("2026-07-03T22:30:00Z"), status: .complete, reason: nil)
        XCTAssertEqual(menuStatusLine(.idle(summer)), "Ostatnio 04.07 00:30 — zakończone")
    }

    func testALongReasonIsCutAtEightyCharacters() {
        let exactly = String(repeating: "ł", count: 80)
        XCTAssertEqual(idle(.failed, reason: exactly), "Ostatnio 26.11 14:00 — błąd: \(exactly)")

        let line = idle(.failed, reason: exactly + "x")
        XCTAssertEqual(line, "Ostatnio 26.11 14:00 — błąd: \(String(repeating: "ł", count: 79))…")
        XCTAssertEqual(line.dropFirst("Ostatnio 26.11 14:00 — błąd: ".count).count, 80)
    }

    func testAFailureWithoutAReason() {
        XCTAssertEqual(idle(.failed), "Ostatnio 26.11 14:00 — błąd")
    }

    func testReadsAWrittenSnapshot() throws {
        let url = try temporaryDirectory().appendingPathComponent("widget.json")
        let snapshot = buildSnapshot(
            status: .failed, reason: "Limit", failureKey: "KSeF 429", invoices: [], now: instant("2026-11-26T13:00:00.250Z")
        )
        try writeSnapshot(snapshot, to: url)

        let status = try XCTUnwrap(readSnapshotStatus(url))

        XCTAssertEqual(status.status, .failed)
        XCTAssertEqual(status.reason, "Limit")
        XCTAssertEqual(status.updatedAt.timeIntervalSince1970, at.timeIntervalSince1970 + 0.25, accuracy: 0.001)
    }

    func testReadsASnapshotWithoutAReason() throws {
        let url = try temporaryDirectory().appendingPathComponent("widget.json")
        try writeSnapshot(buildSnapshot(status: .complete, reason: nil, failureKey: nil, invoices: [], now: at), to: url)
        XCTAssertNil(try XCTUnwrap(readSnapshotStatus(url)).reason)
    }

    func testGarbageAndMissingFilesAreNil() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("widget.json")
        XCTAssertNil(readSnapshotStatus(url))
        for text in ["not json", "[]", "{}", #"{"updatedAt":"x","status":"complete"}"#, #"{"updatedAt":"2026-11-26T13:00:00.000Z","status":"weird"}"#] {
            try text.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertNil(readSnapshotStatus(url), text)
        }
    }
}
