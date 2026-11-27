import Foundation
import Security

/// iOS keeps Keychain items when an app is deleted. UserDefaults does not
/// survive an uninstall, so its absence is the "fresh install" signal: clear
/// leftover Keychain state (PIN/duress, zone key, store keys) before any store
/// reads it. This is what makes a reinstall start at onboarding again.
enum FreshInstall {
    private static let marker = "rm.installPrepared"

    /// Returns true when the state is clean (either already prepared or just
    /// cleared). A locked device can make the Keychain query fail; in that case
    /// the marker is not written and the next foreground call retries.
    @discardableResult
    static func resetIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return true }
        guard deleteAllGenericPasswords() else { return false }

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("rm.") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: marker)
        return true
    }

    private static func deleteAllGenericPasswords() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return true
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return false
        }
        for item in items {
            var delete: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
            if let service = item[kSecAttrService as String] as? String {
                delete[kSecAttrService as String] = service
            }
            if let account = item[kSecAttrAccount as String] as? String {
                delete[kSecAttrAccount as String] = account
            }
            SecItemDelete(delete as CFDictionary)
        }
        return true
    }
}
