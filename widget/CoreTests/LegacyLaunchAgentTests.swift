import XCTest
@testable import KsefCore

final class LegacyLaunchAgentTests: XCTestCase {
    func testFollowsThePlistAsItAppearsAndDisappears() throws {
        let paths = AppPaths(home: try temporaryDirectory())
        XCTAssertFalse(LegacyLaunchAgent.isInstalled(paths))

        try FileManager.default.createDirectory(at: paths.legacyLaunchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: paths.legacyLaunchAgent)
        XCTAssertTrue(LegacyLaunchAgent.isInstalled(paths))

        try FileManager.default.removeItem(at: paths.legacyLaunchAgent)
        XCTAssertFalse(LegacyLaunchAgent.isInstalled(paths))
    }
}
