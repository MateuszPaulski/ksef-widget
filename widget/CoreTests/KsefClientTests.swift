import XCTest
@testable import KsefCore

final class KsefClientTests: XCTestCase {
    private let page: [String: Any] = [
        "hasMore": false,
        "isTruncated": false,
        "permanentStorageHwmDate": "2026-11-26T06:59:00.1234567+00:00",
        "invoices": [Any](),
    ]

    private func setup(_ step: FakeStep, path: String, method: String) -> (KsefHTTP, FakeTransport) {
        let transport = FakeTransport(["\(method) \(path)": .one(step)])
        return (KsefHTTP(apiBase: FakeTransport.base, transport: transport, sleep: { _ in }), transport)
    }

    private func object(_ data: Data?) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? NSDictionary)
    }

    func testQueriesPurchaseInvoicesByPermanentStorage() async throws {
        let path = "/invoices/query/metadata?sortOrder=Asc&pageOffset=2&pageSize=250"
        let (http, transport) = setup(.json(200, page), path: path, method: "POST")
        let from = "2026-11-25T08:00:00.1234567+00:00"

        let result = try await queryMetadata(http: http, token: "tok", window: Window(from: from, to: nil), pageOffset: 2)

        XCTAssertEqual(result, MetadataPage(hasMore: false, isTruncated: false, permanentStorageHwmDate: "2026-11-26T06:59:00.1234567+00:00", invoices: []))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].path, path)
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer tok")
        XCTAssertEqual(try object(requests[0].body), [
            "subjectType": "Subject2",
            "dateRange": ["dateType": "PermanentStorage", "from": from, "restrictToPermanentStorageHwmDate": true],
        ] as NSDictionary)
    }

    func testSendsToVerbatimWhenTheWindowHasOne() async throws {
        let path = "/invoices/query/metadata?sortOrder=Asc&pageOffset=0&pageSize=250"
        let (http, transport) = setup(.json(200, page), path: path, method: "POST")

        _ = try await queryMetadata(http: http, token: "tok", window: Window(from: "2026-01-01T00:00:00Z", to: "2026-04-01T00:00:00.000Z"), pageOffset: 0)

        let requests = await transport.requests
        XCTAssertEqual(try object(requests[0].body), [
            "subjectType": "Subject2",
            "dateRange": [
                "dateType": "PermanentStorage", "from": "2026-01-01T00:00:00Z",
                "to": "2026-04-01T00:00:00.000Z", "restrictToPermanentStorageHwmDate": true,
            ],
        ] as NSDictionary)
    }

    func testDownloadsRawInvoiceBytes() async throws {
        let bytes = Data("<Faktura>\r\n<Nazwa>Spółka ł</Nazwa>\r\n</Faktura>".utf8)
        let number = "5265877635-20261126-0123456789AB-CD"
        let (http, transport) = setup(.reply(status: 200, headers: ["Content-Type": "application/xml"], body: bytes), path: "/invoices/ksef/\(number)", method: "GET")

        let result = try await downloadInvoice(http: http, token: "tok", ksefNumber: number)

        XCTAssertEqual(result, bytes)
        let request = await transport.requests[0]
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/invoices/ksef/\(number)")
        XCTAssertEqual(request.headers["Accept"], "application/xml")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok")
    }

    func testMalformedAnswerNamesTheEndpoint() async {
        let path = "/invoices/query/metadata?sortOrder=Asc&pageOffset=0&pageSize=250"
        let (http, _) = setup(.json(200, ["hasMore": true]), path: path, method: "POST")
        do {
            _ = try await queryMetadata(http: http, token: "tok", window: Window(from: "2026-01-01T00:00:00Z", to: nil), pageOffset: 0)
            XCTFail("expected a decoding failure")
        } catch {
            XCTAssertEqual(errorMessage(error), "Nieprawidłowa odpowiedź KSeF na POST /invoices/query/metadata")
        }
    }
}
