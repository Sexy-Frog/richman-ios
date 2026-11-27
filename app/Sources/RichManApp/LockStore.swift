import Foundation
import Security
import CryptoKit
import CommonCrypto

/// PIN gate with a Keychain-backed salted hash. The PIN itself is never stored,
/// and the item is device-only + unlocked-only. Wrong attempts are counted; the
/// caller wipes local data at the configured threshold.
///
/// New PINs use PBKDF2-HMAC-SHA256 (150k iterations). Older installs with the
/// original single-SHA256 item are verified once and upgraded transparently.
@MainActor
final class LockStore: ObservableObject {
    @Published private(set) var locked = false
    @Published private(set) var failedAttempts = 0
    /// Kept published so Settings updates immediately after set/remove.
    @Published private(set) var hasDuress = false
    /// Length of the emergency code (nil for a legacy code set before the
    /// length was recorded).
    @Published private(set) var duressLength: Int?

    private let service = "works.kelvins.richman.lock"
    private let account = "pin"
    private let duressAccount = "duress"
    private let attemptsKey = "rm.lock.attempts"
    private let pinLengthKey = "rm.lock.pinLength"
    private let duressLengthKey = "rm.lock.duressLength"
    private let pbkdf2Iterations: UInt32 = 150_000

    init() {
        failedAttempts = UserDefaults.standard.integer(forKey: attemptsKey)
        hasDuress = storedHash(account: duressAccount) != nil
        let storedDuressLength = UserDefaults.standard.integer(
            forKey: duressLengthKey
        )
        duressLength = storedDuressLength >= 4 ? storedDuressLength : nil
        locked = hasPIN
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "rm.locked") { locked = true }
        #endif
    }

    var hasPIN: Bool { storedHash(account: account) != nil }

    /// Main PIN length (non-secret UX hint for auto-submit). Defaults to 4.
    var pinLength: Int {
        let value = UserDefaults.standard.integer(forKey: pinLengthKey)
        return value >= 4 ? value : 4
    }

    var wipeAfter: Int {
        let value = UserDefaults.standard.integer(forKey: "rm.wipeAfter")
        return value <= 0 ? 10 : value
    }

    var attemptsLeft: Int { max(0, wipeAfter - failedAttempts) }

    @discardableResult
    func setPIN(_ pin: String) -> Bool {
        guard pin.count >= 4, pin.count <= 8, pin.allSatisfy(\.isNumber) else {
            return false
        }
        let saved = savePIN(pin, account: account)
        if saved {
            UserDefaults.standard.set(pin.count, forKey: pinLengthKey)
        }
        return saved
    }

    /// A second PIN that wipes local data instead of unlocking. Must differ
    /// from the normal PIN.
    @discardableResult
    func setDuress(_ pin: String) -> Bool {
        guard pin.count >= 4, pin.count <= 8,
              pin.count == pinLength,
              pin.allSatisfy(\.isNumber), !check(pin) else { return false }
        let saved = savePIN(pin, account: duressAccount)
        if saved {
            hasDuress = true
            duressLength = pin.count
            UserDefaults.standard.set(pin.count, forKey: duressLengthKey)
        }
        return saved
    }

    func removeDuress() {
        deleteKeychain(account: duressAccount)
        deleteKeychain(account: duressAccount + "2")
        hasDuress = false
        duressLength = nil
        UserDefaults.standard.removeObject(forKey: duressLengthKey)
    }

    func check(_ pin: String) -> Bool {
        check(pin, account: account)
    }

    func checkDuress(_ pin: String) -> Bool {
        check(pin, account: duressAccount)
    }

    /// Check the v2 (PBKDF2) item, then fall back to the legacy SHA256 item and
    /// upgrade it on success.
    private func check(_ pin: String, account: String) -> Bool {
        if let stored = loadKeychain(account: account + "2"),
           stored.count == 48,
           let derived = derivePIN(pin, salt: Data(stored.prefix(16))) {
            return constantTimeEqual(Data(stored.suffix(32)), derived)
        }
        guard let stored = loadKeychain(account: account), stored.count == 48 else {
            return false
        }
        let salt = Data(stored.prefix(16))
        let legacy = legacyHashPIN(pin, salt: salt)
        guard constantTimeEqual(Data(stored.suffix(32)), legacy) else {
            return false
        }
        // Transparent upgrade so the next launch uses PBKDF2.
        _ = savePIN(pin, account: account)
        return true
    }

    func unlock(_ pin: String) -> Bool {
        if check(pin) {
            recordSuccess()
            return true
        }
        recordFailure()
        return false
    }

    @discardableResult
    func recordFailure() -> Bool {
        failedAttempts += 1
        UserDefaults.standard.set(failedAttempts, forKey: attemptsKey)
        return failedAttempts >= wipeAfter
    }

    /// Called after the lock screen has already verified the PIN (so the slow
    /// KDF is not run twice).
    func recordSuccess() {
        failedAttempts = 0
        UserDefaults.standard.set(0, forKey: attemptsKey)
        locked = false
    }

    func lock() {
        if hasPIN { locked = true }
    }

    func reset() {
        for suffix in ["", "2"] {
            deleteKeychain(account: account + suffix)
            deleteKeychain(account: duressAccount + suffix)
        }
        locked = false
        hasDuress = false
        duressLength = nil
        failedAttempts = 0
        UserDefaults.standard.set(0, forKey: attemptsKey)
        UserDefaults.standard.removeObject(forKey: pinLengthKey)
        UserDefaults.standard.removeObject(forKey: duressLengthKey)
    }

    private func storedHash(account: String) -> Data? {
        loadKeychain(account: account + "2") ?? loadKeychain(account: account)
    }

    private func savePIN(_ pin: String, account: String) -> Bool {
        let salt = randomSalt()
        guard let hash = derivePIN(pin, salt: salt) else { return false }
        guard saveKeychain(salt + hash, account: account + "2") else { return false }
        deleteKeychain(account: account)
        return true
    }

    /// Legacy verifier kept only to migrate existing installs.
    private func legacyHashPIN(_ pin: String, salt: Data) -> Data {
        var data = salt
        data.append(Data(pin.utf8))
        return Data(SHA256.hash(data: data))
    }

    private func derivePIN(_ pin: String, salt: Data) -> Data? {
        var out = Data(count: 32)
        let pinBytes = Data(pin.utf8)
        let status = out.withUnsafeMutableBytes { outBuffer in
            salt.withUnsafeBytes { saltBuffer in
                pinBytes.withUnsafeBytes { pinBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBuffer.bindMemory(to: Int8.self).baseAddress,
                        pinBytes.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        outBuffer.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
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
