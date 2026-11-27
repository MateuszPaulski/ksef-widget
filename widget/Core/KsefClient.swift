import Foundation

let pageSize = 250
private let authPollIntervalMs = 1000
private let authMaxPolls = 120
private let statusInProgress = 100
private let statusSuccess = 200

struct AccessToken: Decodable, Equatable, Sendable {
    let token: String
    let validUntil: String
}

public struct Seller: Codable, Equatable, Sendable {
    let nip: String
    let name: String?
}

enum Subject: String, Decodable, Sendable {
    case seller = "Subject1", buyer = "Subject2"
}

public struct InvoiceMetadata: Codable, Equatable, Sendable {
    let ksefNumber: String
    let invoiceNumber: String
    let issueDate: String  // YYYY-MM-DD
    let permanentStorageDate: String
    let seller: Seller
    let grossAmount: Double
    let currency: String
    let invoiceHash: String  // SHA-256, Base64
    var netAmount: Double?
    var vatAmount: Double?
    var invoiceType: String?
}

struct MetadataPage: Decodable, Equatable {
    let hasMore: Bool
    let isTruncated: Bool
    let permanentStorageHwmDate: String?
    let invoices: [InvoiceMetadata]
}

struct Window: Equatable, Sendable {
    let from: String
    let to: String?
}

private struct Challenge: Decodable {
    let challenge: String
}

private struct AcceptedAuthentication: Decodable {
    struct Token: Decodable { let token: String }
    let referenceNumber: String
    let authenticationToken: Token
}

private struct AuthenticationStatus: Decodable {
    struct Status: Decodable {
        let code: Int
        let description: String
        let details: [String]?
    }
    let status: Status
}

private struct RedeemedTokens: Decodable {
    let accessToken: AccessToken
}

func authenticate(
    http: KsefHTTP, credentials: Credentials, nip: String, environment: KsefEnvironment,
    now: @Sendable () -> Date, sleep: @Sendable (Int) async -> Void
) async throws -> AccessToken {
    let challenge = try decodeKsef(
        Challenge.self, from: try await http.send("POST", "/auth/challenge"), endpoint: "POST /auth/challenge"
    ).challenge

    let signedXml = try signXades(challenge: challenge, nip: nip, credentials: credentials, signingTime: now())
    // Self-signed certificates are accepted on TEST only when KSeF is told not to verify the chain.
    let uploadPath = environment == .test ? "/auth/xades-signature?verifyCertificateChain=false" : "/auth/xades-signature"
    let accepted = try decodeKsef(
        AcceptedAuthentication.self, from: try await http.send("POST", uploadPath, xml: signedXml),
        endpoint: "POST /auth/xades-signature"
    )
    let authToken = accepted.authenticationToken.token

    for poll in 0..<authMaxPolls {
        if poll > 0 { await sleep(authPollIntervalMs) }
        let status = try decodeKsef(
            AuthenticationStatus.self,
            from: try await http.send("GET", "/auth/\(accepted.referenceNumber)", token: authToken),
            endpoint: "GET /auth/{referenceNumber}"
        ).status
        if status.code == statusSuccess {
            return try decodeKsef(
                RedeemedTokens.self, from: try await http.send("POST", "/auth/token/redeem", token: authToken),
                endpoint: "POST /auth/token/redeem"
            ).accessToken
        }
        if status.code != statusInProgress {
            let details = status.details.flatMap { $0.isEmpty ? nil : " — " + $0.joined(separator: ", ") } ?? ""
            throw KsefError("Uwierzytelnienie w KSeF nieudane (kod \(status.code): \(status.description)\(details))")
        }
    }
    throw KsefError("Uwierzytelnienie w KSeF nie zakończyło się w \(authMaxPolls * authPollIntervalMs / 1000) s")
}

func queryMetadata(http: KsefHTTP, token: String, subject: Subject, window: Window, pageOffset: Int) async throws -> MetadataPage {
    var dateRange: [(String, JSONValue)] = [("dateType", .string("PermanentStorage")), ("from", .string(window.from))]
    if let to = window.to { dateRange.append(("to", .string(to))) }
    dateRange.append(("restrictToPermanentStorageHwmDate", .bool(true)))
    let body = JSONValue.object([("subjectType", .string(subject.rawValue)), ("dateRange", .object(dateRange))])

    let data = try await http.send(
        "POST", "/invoices/query/metadata?sortOrder=Asc&pageOffset=\(pageOffset)&pageSize=\(pageSize)", token: token, json: body
    )
    return try decodeKsef(MetadataPage.self, from: data, endpoint: "POST /invoices/query/metadata")
}

func downloadInvoice(http: KsefHTTP, token: String, ksefNumber: String) async throws -> Data {
    try await http.send("GET", "/invoices/ksef/\(ksefNumber)", token: token, accept: "application/xml")
}
