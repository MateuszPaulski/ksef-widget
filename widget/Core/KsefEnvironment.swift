import Foundation

public enum KsefEnvironment: String, Codable, CaseIterable, Sendable {
    case test, demo, prod

    var apiBase: String {
        switch self {
        case .test: "https://api-test.ksef.mf.gov.pl/v2"
        case .demo: "https://api-demo.ksef.mf.gov.pl/v2"
        case .prod: "https://api.ksef.mf.gov.pl/v2"
        }
    }

    var qrBase: String {
        switch self {
        case .test: "https://qr-test.ksef.mf.gov.pl"
        case .demo: "https://qr-demo.ksef.mf.gov.pl"
        case .prod: "https://qr.ksef.mf.gov.pl"
        }
    }
}
