import Foundation
import Security

/// iOS keeps Keychain items when an app is deleted. UserDefaults does not
/// survive an uninstall, so its absence is the "fresh install" signal: clear
/// leftover Keychain state (PIN/duress, zone key, store keys) before any store
/// reads it. This is what makes a reinstall start at onboarding again.
enum FreshInstall {
    private static let marker = "rm.installPrepared"
    private static let deviceKey = "rm.installID"
    private static let deviceService = "works.kelvins.richman.device"
    private static let deviceAccount = "install"

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

    /// The sealed stores and Keychain keys can be cloned by a backup or a
    /// device-to-device transfer. A ThisDeviceOnly marker survives a normal
    /// reinstall on the same phone but not a migration; if the marker is
    /// missing while UserDefaults says this install existed, reset the local
    /// identity so two phones never share mailboxes.
    static func bindDeviceIfNeeded() {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: deviceKey)
        let result = readDeviceID()
        // Keychain locked/unavailable: never treat that as a clone.
        if result.status != errSecSuccess && result.status != errSecItemNotFound {
            return
        }
        let current = result.value

        if stored == nil && current == nil {
            let id = UUID().uuidString
            defaults.set(id, forKey: deviceKey)
            _ = saveDeviceID(id)
            return
        }
        if let stored, let current, stored == current { return }

        _ = deleteAllGenericPasswords()
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("rm.") {
            defaults.removeObject(forKey: key)
        }
        LocalStore.wipe()
        MediaStore.clearAll()
        PrivacyStorage.wipeCaches()
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        try? FileManager.default.removeItem(
            at: base.appendingPathComponent("signal.store")
        )
        defaults.set(true, forKey: marker)
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceKey)
        _ = saveDeviceID(id)
    }

    private static func readDeviceID() -> (value: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceService,
            kSecAttrAccount as String: deviceAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
    }

    private static func saveDeviceID(_ id: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: deviceService,
            kSecAttrAccount as String: deviceAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(id.utf8)
        add[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
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
