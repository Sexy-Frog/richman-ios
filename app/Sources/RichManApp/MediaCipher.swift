import Foundation
import CryptoKit
import Security

/// Media at rest is sealed with a Keychain-only AES-256-GCM key. The on-disk
/// container is `RMED` + version + combined nonce/ciphertext/tag, so legacy
/// plaintext files can still be read and are migrated on the next save.
///
/// On unsigned CI/demo builds the Keychain may be unavailable; in that case
/// callers fall back to plaintext so screenshots keep working. Device builds
/// are signed and always use the sealed path.
enum MediaCipher {
    private static let service = "works.kelvins.richman.media"
    private static let account = "media-key"
    private static let marker = Data([0x52, 0x4D, 0x45, 0x44, 0x01]) // RMED v1

    static func isSealed(_ data: Data) -> Bool {
        data.count > marker.count && data.prefix(marker.count) == marker
    }

    static func seal(_ data: Data) -> Data? {
        guard let key = loadKey(),
              let box = try? AES.GCM.seal(data, using: key),
              let combined = box.combined else { return nil }
        var out = marker
        out.append(combined)
        return out
    }

    static func open(_ data: Data) -> Data? {
        guard isSealed(data), let key = loadKey() else { return nil }
        let combined = data.dropFirst(marker.count)
        guard let box = try? AES.GCM.SealedBox(combined: combined) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key)
    }

    static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func loadKey() -> SymmetricKey? {
        if let data = loadKeyData() { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            return nil
        }
        return key
    }

    private static func loadKeyData() -> Data? {
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
}
