import XCTest
@testable import KsefCore

/// XAdES login against KSeF TEST with a self-signed certificate and a random NIP. Never point this at another environment.
final class AuthE2ETests: XCTestCase {
    func testAuthenticatesARandomNipWithASelfSignedRsaCertificate() async throws {
        try await authenticateRandomNip(keyType: .rsa)
    }

    func testAuthenticatesARandomNipWithASelfSignedEcCertificate() async throws {
        try await authenticateRandomNip(keyType: .ec)
    }

    private func authenticateRandomNip(keyType: KeyType) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ksef-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let nip = randomNip()
        let files = try TestCredentials.make(nip: nip, keyType: keyType, in: dir)
        let credentials = try loadCredentials(certificateURL: files.certificateURL, keyURL: files.keyURL, password: files.password)
        let sleep: @Sendable (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) }
        let http = KsefHTTP(apiBase: KsefEnvironment.test.apiBase, transport: URLSessionTransport(), sleep: sleep)

        let accessToken = try await authenticate(
            http: http, credentials: credentials, nip: nip, environment: .test, now: { Date() }, sleep: sleep
        )

        XCTAssertFalse(accessToken.token.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(KsefTime.millis(accessToken.validUntil)), KsefTime.millis(Date()))
    }
}
