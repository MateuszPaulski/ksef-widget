import XCTest
@testable import KsefCore

final class HTTPTests: XCTestCase {
    private func setup(_ steps: [FakeStep]) -> (http: KsefHTTP, transport: FakeTransport, sleeps: SleepLog) {
        let transport = FakeTransport(steps: steps)
        let sleeps = SleepLog()
        return (KsefHTTP(apiBase: FakeTransport.base, transport: transport, sleep: { await sleeps.record($0) }), transport, sleeps)
    }

    private func rateLimited(_ retryAfter: String? = nil) -> FakeStep {
        .reply(status: 429, headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
    }

    private let offline = FakeStep.fail(URLError(.notConnectedToInternet))

    func testWaitsOutAShortRetryAfter() async throws {
        let (http, _, sleeps) = setup([rateLimited("5"), .text(200, "ok")])
        let data = try await http.send("GET", "/x")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        let slept = await sleeps.milliseconds
        XCTAssertEqual(slept, [5000])
    }

    func testCountsAMissingRetryAfterAs60S() async throws {
        let (http, _, sleeps) = setup([rateLimited(), .text(200, "ok")])
        _ = try await http.send("GET", "/x")
        let slept = await sleeps.milliseconds
        XCTAssertEqual(slept, [60_000])
    }

    func testEndsWithRateLimitErrorOnALongRetryAfter() async {
        let (http, _, sleeps) = setup([rateLimited("600")])
        do {
            _ = try await http.send("GET", "/x")
            XCTFail("expected RateLimitError")
        } catch let error as RateLimitError {
            XCTAssertEqual(error.retryAfterSeconds, 600)
            XCTAssertEqual(errorMessage(error), "Limit zapytań KSeF — trzeba odczekać 600 s.")
        } catch {
            XCTFail("\(error)")
        }
        let slept = await sleeps.milliseconds
        XCTAssertEqual(slept, [])
    }

    func testTreatsANonNumericRetryAfterAsLongerThanTheThreshold() async {
        let (http, _, sleeps) = setup([rateLimited("soon")])
        do {
            _ = try await http.send("GET", "/x")
            XCTFail("expected RateLimitError")
        } catch let error as RateLimitError {
            XCTAssertEqual(error.retryAfterSeconds, 3600)
        } catch {
            XCTFail("\(error)")
        }
        let slept = await sleeps.milliseconds
        XCTAssertEqual(slept, [])
    }

    func testGivesUpAfterThreeRateLimitRetries() async {
        let (http, transport, sleeps) = setup([rateLimited("1"), rateLimited("1"), rateLimited("1"), rateLimited("1")])
        do {
            _ = try await http.send("GET", "/x")
            XCTFail("expected RateLimitError")
        } catch is RateLimitError {
        } catch {
            XCTFail("\(error)")
        }
        let count = await transport.requests.count
        let slept = await sleeps.milliseconds
        XCTAssertEqual(count, 4)
        XCTAssertEqual(slept, [1000, 1000, 1000])
    }

    func testRetriesNetworkErrors() async throws {
        let (http, _, sleeps) = setup([offline, offline, .text(200, "ok")])
        let data = try await http.send("GET", "/x")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        let slept = await sleeps.milliseconds
        XCTAssertEqual(slept, [30_000, 30_000])
    }

    func testFailsAfterTheNetworkRetriesAreUsedUp() async {
        let (http, transport, _) = setup([offline, offline, offline, offline])
        do {
            _ = try await http.send("GET", "/x")
            XCTFail("expected a connection error")
        } catch {
            XCTAssertTrue(errorMessage(error).hasPrefix("Brak połączenia z KSeF: "), errorMessage(error))
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 4)
    }

    func testKeepsTheTwoRetryBudgetsIndependent() async throws {
        let (http, transport, _) = setup([
            rateLimited("1"), rateLimited("1"), rateLimited("1"),
            offline, offline, offline,
            .text(200, "ok"),
        ])
        _ = try await http.send("GET", "/x")
        let count = await transport.requests.count
        XCTAssertEqual(count, 7)
    }

    func testDoesNotRetryServerErrors() async {
        let (http, transport, sleeps) = setup([.text(500, "{\"x\":1}")])
        do {
            _ = try await http.send("GET", "/x")
            XCTFail("expected KsefApiError")
        } catch let error as KsefApiError {
            XCTAssertEqual(error.status, 500)
            XCTAssertEqual(errorMessage(error), "KSeF odpowiedział 500 na GET /x: {\"x\":1}")
        } catch {
            XCTFail("\(error)")
        }
        let count = await transport.requests.count
        let slept = await sleeps.milliseconds
        XCTAssertEqual(count, 1)
        XCTAssertEqual(slept, [])
    }

    func testPassesAFreshTimeoutOnEveryAttempt() async throws {
        let (http, transport, _) = setup([offline, .text(200, "ok")])
        _ = try await http.send("GET", "/x")
        let timeouts = await transport.requests.map(\.timeoutInterval)
        XCTAssertEqual(timeouts, [60, 60])
    }

    func testSessionTimeouts() {
        let configuration = URLSessionTransport().configuration
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 60)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testSendsHeadersAndBodies() async throws {
        let (http, transport, _) = setup([.text(200, ""), .text(200, ""), .text(200, "")])
        _ = try await http.send("POST", "/j", token: "tok", json: .object([("a", .number(1))]))
        _ = try await http.send("POST", "/x", xml: "<a/>")
        _ = try await http.send("GET", "/g", accept: "application/xml")
        let requests = await transport.requests
        XCTAssertEqual(requests[0].headers, ["Accept": "application/json", "Authorization": "Bearer tok", "Content-Type": "application/json"])
        XCTAssertEqual(requests[0].bodyText, "{\"a\":1}")
        XCTAssertEqual(requests[1].headers, ["Accept": "application/json", "Content-Type": "application/xml"])
        XCTAssertEqual(requests[1].bodyText, "<a/>")
        XCTAssertEqual(requests[2].headers, ["Accept": "application/xml"])
        XCTAssertNil(requests[2].body)
    }
}
