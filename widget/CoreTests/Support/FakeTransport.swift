import Foundation
@testable import KsefCore

enum FakeStep: Sendable {
    case reply(status: Int, headers: [String: String] = [:], body: Data = Data())
    case fail(any Error)

    static func text(_ status: Int, _ body: String, headers: [String: String] = [:]) -> FakeStep {
        .reply(status: status, headers: headers, body: Data(body.utf8))
    }

    static func json(_ status: Int, _ object: Any) -> FakeStep {
        .reply(status: status, headers: ["Content-Type": "application/json"], body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

enum FakeAnswer: Sendable {
    case one(FakeStep)
    case queue([FakeStep])
    case each(@Sendable () -> FakeStep)
}

struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
    let timeoutInterval: TimeInterval

    var bodyText: String? { body.map { String(decoding: $0, as: UTF8.self) } }
}

/// Answers by "METHOD path?query"; with `steps` every request takes the next step whatever its path.
actor FakeTransport: HTTPTransport {
    static let base = "https://ksef.example.test/v2"

    private var answers: [String: FakeAnswer]
    private var steps: [FakeStep]?
    private(set) var requests: [RecordedRequest] = []

    init(_ answers: [String: FakeAnswer]) {
        self.answers = answers
    }

    init(steps: [FakeStep]) {
        answers = [:]
        self.steps = steps
    }

    var summaries: [String] { requests.map { "\($0.method) \($0.path)" } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw FakeFailure(description: "request without URL") }
        let path = String(url.absoluteString.dropFirst(Self.base.count))
        let method = request.httpMethod ?? "GET"
        requests.append(RecordedRequest(
            method: method, path: path, headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody, timeoutInterval: request.timeoutInterval
        ))

        let step: FakeStep
        if steps != nil {
            guard !steps!.isEmpty else { throw FakeFailure(description: "unexpected extra request \(method) \(path)") }
            step = steps!.removeFirst()
        } else {
            switch answers["\(method) \(path)"] {
            case .one(let single): step = single
            case .queue(var queue): step = queue.removeFirst(); answers["\(method) \(path)"] = .queue(queue)
            case .each(let make): step = make()
            case nil: throw FakeFailure(description: "unexpected request \(method) \(path)")
            }
        }
        switch step {
        case .fail(let error): throw error
        case .reply(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, response)
        }
    }
}

struct FakeFailure: Error, CustomStringConvertible {
    let description: String
}

actor SleepLog {
    private(set) var milliseconds: [Int] = []

    func record(_ value: Int) { milliseconds.append(value) }
}
