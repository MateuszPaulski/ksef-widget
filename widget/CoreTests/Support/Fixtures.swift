import Foundation
import XCTest

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

extension XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ksef-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
