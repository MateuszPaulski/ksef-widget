import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public var nip: String
    public var environment: KsefEnvironment
    public var startDate: String  // YYYY-MM-DD
    public var dataDir: String
    public var verified: Bool

    public init(nip: String, environment: KsefEnvironment, startDate: String, dataDir: String, verified: Bool) {
        self.nip = nip
        self.environment = environment
        self.startDate = startDate
        self.dataDir = dataDir
        self.verified = verified
    }
}
