import Foundation
import Observation
import MailEngine

@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [Account] = []
    private static let file = "accounts.json"

    init() {
        accounts = Storage.load([Account].self, from: Self.file) ?? []
    }

    func password(for account: Account) -> String {
        Keychain.get(account.passwordKey) ?? ""
    }

    func account(_ id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    /// Adds or replaces an account. A nil password keeps the stored one.
    func save(_ account: Account, password: String?) {
        if let password { Keychain.set(password, for: account.passwordKey) }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        Storage.save(accounts, to: Self.file)
    }

    func remove(_ account: Account) {
        Keychain.delete(account.passwordKey)
        accounts.removeAll { $0.id == account.id }
        Storage.save(accounts, to: Self.file)
    }
}
