import Foundation

private let maxRetryAfterSeconds = 120
private let maxRateLimitRetries = 3
private let networkRetries = 3
private let networkRetryDelayMs = 30_000
private let requestTimeoutSeconds: TimeInterval = 60
private let defaultRetryAfterSeconds = 60
// A Retry-After we cannot parse is treated as a long wait (the hourly limits are the usual cause).
private let unparseableRetryAfterSeconds = 3600
private let bodyExcerptCharacters = 300

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    var configuration: URLSessionConfiguration { session.configuration }

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        // Unlike the per-request interval, this caps the whole transfer, as AbortSignal.timeout does.
        configuration.timeoutIntervalForResource = requestTimeoutSeconds
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

struct KsefApiError: LocalizedError {
    let status: Int
    let method: String
    let path: String
    let body: String

    var errorDescription: String? {
        "KSeF odpowiedział \(status) na \(method) \(path): \(body.prefix(bodyExcerptCharacters))"
    }
}

struct RateLimitError: LocalizedError {
    let retryAfterSeconds: Int

    var errorDescription: String? { "Limit zapytań KSeF — trzeba odczekać \(retryAfterSeconds) s." }
}

private func retryAfterSeconds(_ response: HTTPURLResponse) -> Int {
    guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return defaultRetryAfterSeconds }
    let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
    let isDigits = !trimmed.isEmpty && trimmed.utf8.allSatisfy { (48...57).contains($0) }
    return isDigits ? Int(trimmed) ?? unparseableRetryAfterSeconds : unparseableRetryAfterSeconds
}

struct KsefHTTP: Sendable {
    let apiBase: String
    let transport: any HTTPTransport
    let sleep: @Sendable (Int) async -> Void  // milliseconds

    init(apiBase: String, transport: any HTTPTransport, sleep: @escaping @Sendable (Int) async -> Void) {
        self.apiBase = apiBase
        self.transport = transport
        self.sleep = sleep
    }

    func send(
        _ method: String, _ path: String, token: String? = nil, json: JSONValue? = nil, xml: String? = nil,
        accept: String = "application/json"
    ) async throws -> Data {
        guard let url = URL(string: apiBase + path) else { throw KsefError("Nieprawidłowy adres żądania do KSeF: \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(json.compact().utf8)
        } else if let xml {
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(xml.utf8)
        }

        var rateLimitRetries = 0
        var networkFailures = 0
        while true {
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                if networkFailures == networkRetries { throw KsefError("Brak połączenia z KSeF: \(error.localizedDescription)") }
                networkFailures += 1
                await sleep(networkRetryDelayMs)
                continue
            }
            if response.statusCode == 429 {
                let seconds = retryAfterSeconds(response)
                if seconds > maxRetryAfterSeconds || rateLimitRetries == maxRateLimitRetries { throw RateLimitError(retryAfterSeconds: seconds) }
                rateLimitRetries += 1
                await sleep(seconds * 1000)
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw KsefApiError(status: response.statusCode, method: method, path: path, body: String(decoding: data, as: UTF8.self))
            }
            return data
        }
    }
}

func decodeKsef<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw KsefError("Nieprawidłowa odpowiedź KSeF na \(endpoint)")
    }
}
