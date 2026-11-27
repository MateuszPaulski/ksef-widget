import Security
import XCTest
@testable import KsefCore

/// Touches the real login Keychain, so it runs only on request: `TEST_RUNNER_KSEF_KEYCHAIN_TEST=1`. It uses a throwaway service.
final class KeychainAdapterTests: XCTestCase {
    func testRoundTripWithAThrowawayItem() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KSEF_KEYCHAIN_TEST"] == "1", "set KSEF_KEYCHAIN_TEST=1 to run")

        let service = "local.ksef-daily-fetch.keychain-test.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: KeychainSecretStore.account,
        ]
        defer { SecItemDelete(item as CFDictionary) }

        func assertMissing(line: UInt = #line) {
            XCTAssertThrowsError(try store.readKeyPassword(), line: line) {
                XCTAssertEqual(errorMessage($0), KeychainSecretStore.missingPasswordMessage, line: line)
            }
        }

        assertMissing()
        try store.saveKeyPassword("pierwsze hasło ąę")
        XCTAssertEqual(try store.readKeyPassword(), "pierwsze hasło ąę")
        try store.saveKeyPassword("drugie hasło żółć")
        XCTAssertEqual(try store.readKeyPassword(), "drugie hasło żółć")

        XCTAssertEqual(SecItemDelete(item as CFDictionary), errSecSuccess)
        assertMissing()
    }
}
