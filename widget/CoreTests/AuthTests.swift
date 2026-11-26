import XCTest
@testable import KsefCore

final class AuthTests: XCTestCase {
    private let nip = "5265877635"
    private let reference = "a1b2c3d4-0000-4000-8000-000000000000"
    private var credentials: Credentials!

    override func setUpWithError() throws {
        let files = try TestCredentials.make(nip: randomNip(), keyType: .rsa, in: try temporaryDirectory())
        credentials = try loadCredentials(certificateURL: files.certificateURL, keyURL: files.keyURL, password: files.password)
    }

    private let challenge = FakeStep.json(200, ["challenge": "20261126-CR-0123456789-ABCDEF0123-AB", "timestamp": "2026-11-26T08:00:00+00:00", "timestampMs": 1, "clientIp": "127.0.0.1"])
    private var accepted: FakeStep {
        .json(202, ["referenceNumber": reference, "authenticationToken": ["token": "auth-token", "validUntil": "2026-11-26T08:10:00+00:00"]])
    }
    private let redeemed = FakeStep.json(200, [
        "accessToken": ["token": "acc", "validUntil": "2026-11-26T08:15:00+00:00"],
        "refreshToken": ["token": "ref", "validUntil": "2026-11-27T08:00:00+00:00"],
    ])

    private func status(_ code: Int, extra: [String: Any] = [:]) -> FakeStep {
        .json(200, ["status": ["code": code, "description": "x"].merging(extra) { $1 }])
    }

    private func run(_ transport: FakeTransport, environment: KsefEnvironment = .test) async throws -> (AccessToken, [Int]) {
        let sleeps = SleepLog()
        let http = KsefHTTP(apiBase: FakeTransport.base, transport: transport, sleep: { await sleeps.record($0) })
        let token = try await authenticate(
            http: http, credentials: credentials, nip: nip, environment: environment,
            now: { Date() }, sleep: { await sleeps.record($0) }
        )
        return (token, await sleeps.milliseconds)
    }

    func testAuthenticatesChallengeSignedXmlPollsUntil200Redeems() async throws {
        let transport = FakeTransport([
            "POST /auth/challenge": .one(challenge),
            "POST /auth/xades-signature?verifyCertificateChain=false": .one(accepted),
            "GET /auth/\(reference)": .queue([status(100), status(100), status(200)]),
            "POST /auth/token/redeem": .one(redeemed),
        ])

        let (token, sleeps) = try await run(transport)

        XCTAssertEqual(token, AccessToken(token: "acc", validUntil: "2026-11-26T08:15:00+00:00"))
        let summaries = await transport.summaries
        XCTAssertEqual(summaries, [
            "POST /auth/challenge",
            "POST /auth/xades-signature?verifyCertificateChain=false",
            "GET /auth/\(reference)",
            "GET /auth/\(reference)",
            "GET /auth/\(reference)",
            "POST /auth/token/redeem",
        ])
        XCTAssertEqual(sleeps, [1000, 1000])
        let requests = await transport.requests
        XCTAssertEqual(requests[1].headers["Content-Type"], "application/xml")
        XCTAssertTrue(try XCTUnwrap(requests[1].bodyText).contains("<ds:Signature"))
        XCTAssertTrue(try XCTUnwrap(requests[1].bodyText).contains("<Challenge>20261126-CR-0123456789-ABCDEF0123-AB</Challenge>"))
        for request in requests.dropFirst(2) {
            XCTAssertEqual(request.headers["Authorization"], "Bearer auth-token")
        }
    }

    func testOmitsVerifyCertificateChainOutsideTest() async throws {
        let transport = FakeTransport([
            "POST /auth/challenge": .one(challenge),
            "POST /auth/xades-signature": .one(accepted),
            "GET /auth/\(reference)": .one(status(200)),
            "POST /auth/token/redeem": .one(redeemed),
        ])
        _ = try await run(transport, environment: .prod)
        let requests = await transport.requests
        XCTAssertEqual(requests[1].path, "/auth/xades-signature")
    }

    func testFailsWithKsefStatusDetails() async {
        let transport = FakeTransport([
            "POST /auth/challenge": .one(challenge),
            "POST /auth/xades-signature?verifyCertificateChain=false": .one(accepted),
            "GET /auth/\(reference)": .one(status(460, extra: [
                "description": "Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu",
                "details": ["Certyfikat odwołany"],
            ])),
        ])
        do {
            _ = try await run(transport)
            XCTFail("expected an authentication failure")
        } catch {
            XCTAssertEqual(
                errorMessage(error),
                "Uwierzytelnienie w KSeF nieudane (kod 460: Uwierzytelnianie zakończone niepowodzeniem z powodu błędu certyfikatu — Certyfikat odwołany)"
            )
        }
    }

    func testGivesUpAfter120Polls() async {
        let transport = FakeTransport([
            "POST /auth/challenge": .one(challenge),
            "POST /auth/xades-signature?verifyCertificateChain=false": .one(accepted),
            "GET /auth/\(reference)": .each { .json(200, ["status": ["code": 100, "description": "x"]]) },
        ])
        do {
            _ = try await run(transport)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(errorMessage(error), "Uwierzytelnienie w KSeF nie zakończyło się w 120 s")
        }
        let polls = await transport.requests.filter { $0.path == "/auth/\(reference)" }.count
        XCTAssertEqual(polls, 120)
    }

    func testTurnsANon2xxAnswerIntoKsefApiError() async {
        let transport = FakeTransport(["POST /auth/challenge": .one(.json(500, ["x": 1]))])
        do {
            _ = try await run(transport)
            XCTFail("expected KsefApiError")
        } catch let error as KsefApiError {
            XCTAssertEqual(error.status, 500)
            XCTAssertEqual(errorMessage(error), "KSeF odpowiedział 500 na POST /auth/challenge: {\"x\":1}")
        } catch {
            XCTFail("\(error)")
        }
    }
}
