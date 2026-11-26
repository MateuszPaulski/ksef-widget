import XCTest

final class KsefLinkTests: XCTestCase {
    func testAllowed() {
        for string in [
            "https://qr.ksef.mf.gov.pl/invoice/x",
            "https://qr-test.ksef.mf.gov.pl/x",
            "https://qr-demo.ksef.mf.gov.pl/x",
        ] {
            XCTAssertTrue(KsefLink.isAllowed(URL(string: string)!), string)
        }
    }

    func testRejected() {
        for string in [
            "http://qr.ksef.mf.gov.pl/x",
            "https://qr.ksef.mf.gov.pl.evil.example/x",
            "https://evil.example/qr.ksef.mf.gov.pl",
            "https://user@qr.ksef.mf.gov.pl/x",
            "javascript:alert(1)",
            "file:///etc/passwd",
        ] {
            XCTAssertFalse(KsefLink.isAllowed(URL(string: string)!), string)
        }
    }
}
