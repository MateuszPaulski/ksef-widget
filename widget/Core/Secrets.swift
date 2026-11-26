import Foundation
import Security

public protocol SecretStore: Sendable {
    func readKeyPassword() throws -> String
    func saveKeyPassword(_ password: String) throws
}

/// One generic-password item in the login keychain. No data protection keychain: it needs a provisioning profile.
public struct KeychainSecretStore: SecretStore {
    static let service = "local.ksef-daily-fetch.KsefWidget"
    static let account = "key-password"
    static let label = "KSeF — hasło klucza prywatnego"
    static let missingPasswordMessage = "Brak hasła klucza w Pęku kluczy (usługa \(service), konto \(account))"

    public init() {}

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
    }

    public func readKeyPassword() throws -> String {
        var result: CFTypeRef?
        let query = identity.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KsefError(Self.missingPasswordMessage) }
        guard status == errSecSuccess else { throw Self.failure(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KsefError("Pęk kluczy: hasło ma nieprawidłowy format")
        }
        return password
    }

    public func saveKeyPassword(_ password: String) throws {
        let data = Data(password.utf8)
        var status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            let item = identity.merging([kSecValueData as String: data, kSecAttrLabel as String: Self.label]) { $1 }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    private static func failure(_ status: OSStatus) -> KsefError {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "nieznany błąd"
        return KsefError("Pęk kluczy: \(text) (OSStatus \(status))")
    }
}
