import Foundation
@testable import KsefCore

final class FakeSecretStore: SecretStore {
    private let passwords: Locked<[String]>
    private let stored: Locked<String?>

    init(password: String? = nil) {
        passwords = Locked([])
        stored = Locked(password)
    }

    var saved: [String] { passwords.value }

    func readKeyPassword() throws -> String {
        guard let password = stored.value else { throw KsefError(KeychainSecretStore.missingPasswordMessage) }
        return password
    }

    func saveKeyPassword(_ password: String) throws {
        passwords.update { $0.append(password) }
        stored.value = password
    }
}
