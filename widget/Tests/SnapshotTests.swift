import XCTest

final class SnapshotTests: XCTestCase {
    func testDecodesTheContract() throws {
        let snapshot = try SnapshotFile.decode(Data(Fixtures.contractJSON.utf8))
        XCTAssertEqual(snapshot.updatedAt.timeIntervalSince1970, Fixtures.updatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snapshot.status, .complete)
        XCTAssertNil(snapshot.reason)
        XCTAssertEqual(snapshot.today, "2026-11-26")
        XCTAssertEqual(snapshot.savedToday, 2)
        XCTAssertEqual(snapshot.invoices[0].amount, "1230,00 PLN")
        XCTAssertEqual(snapshot.invoices[0].seller, "Acme Sp. z o.o.")
    }

    func testDecodesTheYearSummary() throws {
        let summary = "2026 · wydatki 43,60 PLN · przychody 0,00 PLN"
        let json = Fixtures.contractJSON.replacingOccurrences(
            of: "\n    }\n  ]\n}",
            with: "\n    }\n  ],\n  \"yearSummary\": {\"text\": \"\(summary)\", \"warning\": false}\n}")
        XCTAssertNotEqual(json, Fixtures.contractJSON)
        let snapshot = try SnapshotFile.decode(Data(json.utf8))
        XCTAssertEqual(snapshot.yearSummary, Snapshot.YearSummary(text: summary, warning: false))
    }

    func testTheContractWithoutAYearSummaryHasNoFooter() throws {
        let snapshot = try SnapshotFile.decode(Data(Fixtures.contractJSON.utf8))
        XCTAssertNil(snapshot.yearSummary)
        XCTAssertNil(WidgetModel.make(.success(snapshot), now: Fixtures.now).footer)
    }

    func testDecodesWithoutMilliseconds() throws {
        let json = Fixtures.contractJSON.replacingOccurrences(of: "2026-11-26T13:00:41.123Z", with: "2026-11-26T13:00:41Z")
        let snapshot = try SnapshotFile.decode(Data(json.utf8))
        XCTAssertEqual(snapshot.updatedAt.timeIntervalSince1970, Fixtures.updatedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testIgnoresFailureKey() throws {
        let json = Fixtures.contractJSON.replacingOccurrences(
            of: "\"status\": \"complete\",",
            with: "\"status\": \"failed\",\n  \"reason\": \"x\",\n  \"failureKey\": \"KSeF 500\",")
        let snapshot = try SnapshotFile.decode(Data(json.utf8))
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertEqual(snapshot.reason, "x")
    }

    func testUnknownStatusIsAnError() {
        let json = Fixtures.contractJSON.replacingOccurrences(of: "\"complete\"", with: "\"weird\"")
        XCTAssertThrowsError(try SnapshotFile.decode(Data(json.utf8)))
    }

    func testMissingFieldIsAnError() {
        let json = Fixtures.contractJSON.replacingOccurrences(of: "\"savedToday\": 2,", with: "")
        XCTAssertThrowsError(try SnapshotFile.decode(Data(json.utf8)))
    }

    func testLoadMissingFile() throws {
        let directory = try makeTemporaryDirectory()
        XCTAssertEqual(SnapshotFile.load(from: directory.appendingPathComponent("widget.json")), .failure(.missing))
    }

    func testLoadGarbage() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("widget.json")
        try Data("{\"updatedAt\":".utf8).write(to: file)
        guard case .failure(.unreadable) = SnapshotFile.load(from: file) else {
            return XCTFail("expected .unreadable")
        }
    }

    func testURLIsUnderTheRealHome() {
        let path = SnapshotFile.url.path
        XCTAssertTrue(path.hasSuffix("/Library/Application Support/ksef-daily-fetch/widget.json"))
        XCTAssertFalse(path.contains("/Library/Containers/"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
