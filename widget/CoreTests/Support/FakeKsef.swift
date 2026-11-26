import CryptoKit
import Foundation
@testable import KsefCore

private let authReference = "20261126-AU-0000000000-0000000000-00"

struct FakeInvoice {
    let metadata: InvoiceMetadata
    let xml: Data
}

/// A purchase invoice whose metadata hash is the real SHA-256 of its XML bytes.
func fakeInvoice(_ n: Int) -> FakeInvoice {
    let xml = Data("<Faktura><P_2>FV/\(n)</P_2></Faktura>".utf8)
    return FakeInvoice(
        metadata: InvoiceMetadata(
            ksefNumber: "5265877635-20261120-\(String(format: "%06X", n))123456-AB", invoiceNumber: "FV/\(n)", issueDate: "2026-11-20",
            permanentStorageDate: "2026-11-20T09:0\(n):00.1234567+00:00", seller: Seller(nip: "1111111111", name: "Sprzedawca \(n)"),
            grossAmount: Double(100 * n) + 0.5, currency: "PLN", invoiceHash: Data(SHA256.hash(data: xml)).base64EncodedString()
        ),
        xml: xml
    )
}

struct FakeDownloadAnswer: Sendable {
    let status: Int
    var headers: [String: String] = [:]
    var body: String = ""
}

struct FakeAuthStatus: Sendable {
    let code: Int
    let description: String
    var details: [String]? = nil
}

struct FakeKsefOptions: Sendable {
    var invoices: [FakeInvoice]
    var hwm: String
    var now: @Sendable () -> Date  // the test's fake clock; token validUntil is derived from it
    var authStatus: FakeAuthStatus?
    var downloadStatus: (@Sendable (String) -> FakeDownloadAnswer?)?
    var fetchError: (any Error)?  // every request throws this
}

private struct MetadataPageBody: Encodable {
    let hasMore = false
    let isTruncated = false
    let permanentStorageHwmDate: String
    let invoices: [InvoiceMetadata]
}

/// In-memory stand-in for the KSeF TEST endpoints used by run(). It does not validate the signature.
actor FakeKsef: HTTPTransport {
    private let options: FakeKsefOptions
    private(set) var requests: [(method: String, path: String)] = []

    init(_ options: FakeKsefOptions) {
        self.options = options
    }

    var ksefRequests: [String] { requests.map(\.path).filter { $0.hasPrefix("/invoices/ksef/") } }

    private func reply(_ status: Int, json: Any? = nil, body: Data = Data(), headers: [String: String] = [:], url: URL) throws -> (Data, HTTPURLResponse) {
        var allHeaders = headers
        var data = body
        if let json {
            data = try JSONSerialization.data(withJSONObject: json)
            allHeaders["Content-Type"] = "application/json"
        }
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: allHeaders)!)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let error = options.fetchError { throw error }
        let url = request.url!
        let path = String(url.absoluteString.dropFirst(KsefEnvironment.test.apiBase.count))
        let method = request.httpMethod ?? "GET"
        requests.append((method, path))
        func iso(_ offsetMs: Int64) -> String { KsefTime.iso(millis: KsefTime.millis(options.now()) + offsetMs) }

        if method == "POST", path == "/auth/challenge" {
            return try reply(200, json: [
                "challenge": "20261126-CR-0123456789-ABCDEF0123-AB", "timestamp": iso(0),
                "timestampMs": KsefTime.millis(options.now()), "clientIp": "203.0.113.1",
            ], url: url)
        }
        if method == "POST", path.hasPrefix("/auth/xades-signature") {
            return try reply(202, json: [
                "referenceNumber": authReference, "authenticationToken": ["token": "auth", "validUntil": iso(10 * 60_000)],
            ], url: url)
        }
        if method == "GET", path == "/auth/\(authReference)" {
            let status = options.authStatus ?? FakeAuthStatus(code: 200, description: "ok")
            var object: [String: Any] = ["code": status.code, "description": status.description]
            if let details = status.details { object["details"] = details }
            return try reply(200, json: ["status": object], url: url)
        }
        if method == "POST", path == "/auth/token/redeem" {
            return try reply(200, json: [
                "accessToken": ["token": "acc", "validUntil": iso(15 * 60_000)],
                "refreshToken": ["token": "ref", "validUntil": iso(24 * 3_600_000)],
            ], url: url)
        }
        if method == "POST", path.hasPrefix("/invoices/query/metadata") {
            let body = MetadataPageBody(permanentStorageHwmDate: options.hwm, invoices: options.invoices.map(\.metadata))
            return try reply(200, body: try JSONEncoder().encode(body), headers: ["Content-Type": "application/json"], url: url)
        }
        if method == "GET", path.hasPrefix("/invoices/ksef/") {
            let ksefNumber = String(path.dropFirst("/invoices/ksef/".count))
            if let answer = options.downloadStatus?(ksefNumber) {
                return try reply(answer.status, body: Data(answer.body.utf8), headers: answer.headers, url: url)
            }
            guard let invoice = options.invoices.first(where: { $0.metadata.ksefNumber == ksefNumber }) else {
                return try reply(404, url: url)
            }
            return try reply(200, body: invoice.xml, headers: ["Content-Type": "application/xml"], url: url)
        }
        return try reply(404, url: url)
    }
}
