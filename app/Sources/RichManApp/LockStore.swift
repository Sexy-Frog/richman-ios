import Foundation
import Security
import CryptoKit

/// PIN gate with a Keychain-backed salted hash. The PIN itself is never stored,
/// and the item is device-only + unlocked-only. Wrong attempts are counted; the
/// caller wipes local data at the configured threshold.
@MainActor
final class LockStore: ObservableObject {
    @Published private(set) var locked = false
    @Published private(set) var failedAttempts = 0

    private let service = "works.kelvins.richman.lock"
    private let account = "pin"
    private let duressAccount = "duress"
    private let attemptsKey = "rm.lock.attempts"

    init() {
        failedAttempts = UserDefaults.standard.integer(forKey: attemptsKey)
        locked = hasPIN
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "rm.locked") { locked = true }
        #endif
    }

    var hasPIN: Bool { loadKeychain(account: account) != nil }

    var hasDuress: Bool { loadKeychain(account: duressAccount) != nil }

    var wipeAfter: Int {
        let value = UserDefaults.standard.integer(forKey: "rm.wipeAfter")
        return value <= 0 ? 10 : value
    }

    var attemptsLeft: Int { max(0, wipeAfter - failedAttempts) }

    @discardableResult
    func setPIN(_ pin: String) -> Bool {
        guard pin.count >= 4, pin.allSatisfy(\.isNumber) else { return false }
        let salt = randomSalt()
        let hash = hashPIN(pin, salt: salt)
        return saveKeychain(salt + hash, account: account)
    }

    /// A second PIN that wipes local data instead of unlocking. Must differ
    /// from the normal PIN.
    @discardableResult
    func setDuress(_ pin: String) -> Bool {
        guard pin.count >= 4, pin.allSatisfy(\.isNumber), !check(pin) else { return false }
        let salt = randomSalt()
        let hash = hashPIN(pin, salt: salt)
        return saveKeychain(salt + hash, account: duressAccount)
    }

    func removeDuress() {
        deleteKeychain(account: duressAccount)
    }

    func check(_ pin: String) -> Bool {
        check(pin, account: account)
    }

    func checkDuress(_ pin: String) -> Bool {
        check(pin, account: duressAccount)
    }

    private func check(_ pin: String, account: String) -> Bool {
        guard let stored = loadKeychain(account: account), stored.count == 48 else {
            return false
        }
        let salt = stored.prefix(16)
        let expected = stored.suffix(32)
        let actual = hashPIN(pin, salt: Data(salt))
        return Data(expected) == actual
    }

    func unlock(_ pin: String) -> Bool {
        if check(pin) {
            failedAttempts = 0
            UserDefaults.standard.set(0, forKey: attemptsKey)
            locked = false
            return true
        }
        failedAttempts += 1
        UserDefaults.standard.set(failedAttempts, forKey: attemptsKey)
        return false
    }

    func lock() {
        if hasPIN { locked = true }
    }

    func reset() {
        deleteKeychain(account: account)
        deleteKeychain(account: duressAccount)
        locked = false
        failedAttempts = 0
        UserDefaults.standard.set(0, forKey: attemptsKey)
    }

    private func hashPIN(_ pin: String, salt: Data) -> Data {
        var data = salt
        data.append(Data(pin.utf8))
        return Data(SHA256.hash(data: data))
    }

    private func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        if status != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    private func saveKeychain(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private func loadKeychain(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private func deleteKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
