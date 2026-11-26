import Foundation
import XCTest
@testable import KsefCore

enum Fixtures {
    static func json<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

struct XadesVector: Decodable {
    let certificatePem: String
    let keyPem: String
    let password: String
    let contextNip: String
    let challenge: String
    let signingTime: String
    let issuer: String
    let serial: String
    let signedXml: String

    static let names = ["xades-rsa", "xades-ec", "xades-awkward-issuer", "xades-organization-identifier"]

    static func load(_ name: String) throws -> XadesVector {
        try Fixtures.json("\(name).json", as: XadesVector.self)
    }
}

struct KeysFixture: Decodable {
    struct Entry: Decodable {
        let name: String
        let certificate: String
        let keyPem: String
        let password: String
        let expect: String
        let oid: String?
    }

    let certificates: [String: String]
    let keys: [Entry]
}

struct FormatsFixture: Decodable {
    struct Notification: Decodable, Equatable {
        let title: String
        let message: String
    }

    struct Amount: Decodable {
        let value: Double
        let text: String

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            value = try container.decode(Double.self)
            text = try container.decode(String.self)
        }
    }

    let now: String
    let invoices: [InvoiceMetadata]
    let indexLines: [String]
    let stateJson: String
    let reportFile: String
    let notifications: [Notification]
    let snapshotJson: String
    let amounts: [Amount]

    static func load() throws -> FormatsFixture {
        try Fixtures.json("formats.json", as: FormatsFixture.self)
    }
}

extension XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ksef-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
