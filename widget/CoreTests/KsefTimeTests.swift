import XCTest
@testable import KsefCore

final class KsefTimeTests: XCTestCase {
    func testParsesKsefSevenDigitFractions() {
        XCTAssertEqual(KsefTime.millis("2026-01-01T00:00:00.1234567+00:00"), 1_767_225_600_123)
        XCTAssertEqual(KsefTime.millis("2026-01-01T00:00:00.9999999+00:00"), 1_767_225_600_999)
        XCTAssertEqual(KsefTime.millis("2026-11-16T00:00:00+00:00"), 1_794_787_200_000)
        XCTAssertEqual(KsefTime.millis("2026-01-01T00:00:00Z"), 1_767_225_600_000)
        XCTAssertEqual(KsefTime.millis("2026-01-01T01:00:00+01:00"), 1_767_225_600_000)
        XCTAssertNil(KsefTime.millis("garbage"))
    }

    func testFormatsLikeToISOString() {
        XCTAssertEqual(KsefTime.iso(millis: 1_767_225_600_999), "2026-01-01T00:00:00.999Z")
        XCTAssertEqual(KsefTime.iso(Date(timeIntervalSince1970: 1_767_225_600.9999)), "2026-01-01T00:00:00.999Z")
    }
}
