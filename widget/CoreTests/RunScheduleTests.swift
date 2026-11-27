import XCTest
@testable import KsefCore

final class RunScheduleTests: XCTestCase {
    private let now = instant("2026-11-26T12:00:00Z")

    func testNoPreviousRunIsDue() {
        XCTAssertTrue(RunSchedule.isDue(lastRunAt: nil, now: now))
    }

    func testFiftyNineMinutesFiftyNineSecondsIsNotDue() {
        XCTAssertFalse(RunSchedule.isDue(lastRunAt: instant("2026-11-26T11:00:01Z"), now: now))
    }

    func testExactlyAnHourIsDue() {
        XCTAssertTrue(RunSchedule.isDue(lastRunAt: instant("2026-11-26T11:00:00Z"), now: now))
    }

    func testALastRunInTheFutureIsDue() {
        XCTAssertTrue(RunSchedule.isDue(lastRunAt: instant("2026-11-26T12:05:00Z"), now: now))
    }

    func testTheIntervalIsAnHour() {
        XCTAssertEqual(RunSchedule.interval, 3600)
    }

    func testLastRunAtPicksTheLaterOfSnapshotAndRunEnd() throws {
        let snapshot = try writeSnapshot(updatedAt: "2026-11-26T11:30:00.000Z", status: "failed")
        let later = instant("2026-11-26T11:45:00Z")
        let earlier = instant("2026-11-26T11:15:00Z")

        XCTAssertEqual(try XCTUnwrap(RunSchedule.lastRunAt(snapshot: snapshot, lastRunEnd: later)).timeIntervalSince1970, later.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(RunSchedule.lastRunAt(snapshot: snapshot, lastRunEnd: earlier)).timeIntervalSince1970,
            instant("2026-11-26T11:30:00Z").timeIntervalSince1970, accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(RunSchedule.lastRunAt(snapshot: snapshot, lastRunEnd: nil)).timeIntervalSince1970,
            instant("2026-11-26T11:30:00Z").timeIntervalSince1970, accuracy: 0.001
        )
    }

    func testAnUnreadableSnapshotFallsBackToTheRunEnd() throws {
        let garbage = try temporaryDirectory().appendingPathComponent("widget.json")
        try "not json".write(to: garbage, atomically: true, encoding: .utf8)
        let missing = try temporaryDirectory().appendingPathComponent("widget.json")
        let end = instant("2026-11-26T11:45:00Z")

        XCTAssertEqual(RunSchedule.lastRunAt(snapshot: garbage, lastRunEnd: end), end)
        XCTAssertEqual(RunSchedule.lastRunAt(snapshot: missing, lastRunEnd: end), end)
        XCTAssertNil(RunSchedule.lastRunAt(snapshot: missing, lastRunEnd: nil))
    }

    func testASnapshotAnHourOldIsDueAndAFreshOneIsNot() throws {
        let stale = try writeSnapshot(updatedAt: "2026-11-26T11:00:00.000Z", status: "complete")
        let fresh = try writeSnapshot(updatedAt: "2026-11-26T11:30:00.000Z", status: "complete")

        XCTAssertTrue(RunSchedule.isDue(lastRunAt: RunSchedule.lastRunAt(snapshot: stale, lastRunEnd: nil), now: now))
        XCTAssertFalse(RunSchedule.isDue(lastRunAt: RunSchedule.lastRunAt(snapshot: fresh, lastRunEnd: nil), now: now))
    }

    @MainActor
    func testRunGateRunsOneAtATime() async {
        let gate = RunGate()
        var release: CheckedContinuation<Void, Never>?
        var secondBodyRan = false
        var thirdBodyRan = false

        let first = Task { @MainActor in
            await gate.runIfIdle {
                await withCheckedContinuation { release = $0 }
            }
        }
        while release == nil { await Task.yield() }
        XCTAssertTrue(gate.isRunning)

        let second = await gate.runIfIdle { secondBodyRan = true }
        XCTAssertFalse(second)
        XCTAssertFalse(secondBodyRan)
        XCTAssertTrue(gate.isRunning)

        release?.resume()
        let firstRan = await first.value
        XCTAssertTrue(firstRan)
        XCTAssertFalse(gate.isRunning)

        let third = await gate.runIfIdle { thirdBodyRan = true }
        XCTAssertTrue(third)
        XCTAssertTrue(thirdBodyRan)
    }

    private func writeSnapshot(updatedAt: String, status: String) throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent("widget.json")
        try #"{"updatedAt":"\#(updatedAt)","status":"\#(status)","today":"2026-11-26","savedToday":0,"invoices":[]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
