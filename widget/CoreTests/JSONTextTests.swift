import XCTest
@testable import KsefCore

final class JSONTextTests: XCTestCase {
    func testEscapesLikeJsonStringify() {
        XCTAssertEqual(
            JSONValue.string("a\"b\\c/d\u{1}\n\t\u{8}\u{c}\rł\u{2028}").compact(),
            "\"a\\\"b\\\\c/d\\u0001\\n\\t\\b\\f\\rł\u{2028}\""
        )
    }

    func testNumbersLikeJavaScript() {
        XCTAssertEqual(JSONValue.number(1230).compact(), "1230")
        XCTAssertEqual(JSONValue.number(200.5).compact(), "200.5")
        XCTAssertEqual(JSONValue.number(0.1 + 0.2).compact(), "0.30000000000000004")
        XCTAssertEqual(JSONValue.number(1e21).compact(), "1e+21")
        XCTAssertEqual(JSONValue.number(-0.0).compact(), "0")
        XCTAssertEqual(JSONValue.number(1e20).compact(), "100000000000000000000")
        XCTAssertEqual(JSONValue.number(-1152921504606846976).compact(), "-1152921504606847000")
        XCTAssertEqual(JSONValue.number(9007199254740992).compact(), "9007199254740992")
    }

    func testPrettyLikeStringifyWithTwoSpaces() {
        let value = JSONValue.object([
            ("a", .number(1)),
            ("b", .array([])),
            ("c", .array([.object([("d", .null)])])),
        ])
        XCTAssertEqual(
            value.pretty(),
            "{\n  \"a\": 1,\n  \"b\": [],\n  \"c\": [\n    {\n      \"d\": null\n    }\n  ]\n}"
        )
        XCTAssertEqual(value.compact(), "{\"a\":1,\"b\":[],\"c\":[{\"d\":null}]}")
    }
}
