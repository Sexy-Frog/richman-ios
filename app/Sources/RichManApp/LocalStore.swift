import Foundation
import CryptoKit
import Security

/// Sealed local state (contacts, chats, groups, mailboxes). Everything except
/// the crypto key material lives here, so a stolen/backed-up file is useless
/// without the Keychain key. Format: `[1][nonce(12)][ciphertext][tag(16)]`.
///
/// This is app-local state, not libsignal state — libsignal records stay in
/// RichManCrypto's own sealed store. Demo/screenshot builds never touch it.
enum LocalStore {
    private static let service = "works.kelvins.richman.state"
    private static let account = "db-key"
    private static let version: UInt8 = 1

    struct State: Codable {
        var contacts: [Contact]
        var groups: [ChatGroup]
        var messages: [String: [ChatMessage]]
        var groupMessages: [String: [ChatMessage]]
        var places: [String: FriendPlace]
        var pendingBoxes: [String]
        var blocked: [String]
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.bin")
    }

    static func load() -> State? {
        guard let sealed = try? Data(contentsOf: fileURL),
              sealed.count > 1 + 12 + 16,
              sealed.first == version,
              let key = existingKey(),
              let box = try? AES.GCM.SealedBox(combined: sealed.dropFirst()),
              let plain = try? AES.GCM.open(box, using: key),
              let state = try? JSONDecoder().decode(State.self, from: plain) else {
            return nil
        }
        return state
    }

    static func save(_ state: State) {
        guard let key = loadOrCreateKey(),
              let plain = try? JSONEncoder().encode(state),
              let box = try? AES.GCM.seal(plain, using: key),
              let combined = box.combined else { return }
        var out = Data([version])
        out.append(combined)
        try? out.write(
            to: fileURL,
            options: [.atomic, .completeFileProtection]
        )
    }

    /// Emergency wipe: delete the ciphertext and destroy its key.
    static func wipe() {
        try? FileManager.default.removeItem(at: fileURL)
        deleteKey()
    }

    // MARK: keychain

    private static func loadKey() -> Data? {
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

    private static func existingKey() -> SymmetricKey? {
        loadKey().map { SymmetricKey(data: $0) }
    }

    private static func loadOrCreateKey() -> SymmetricKey? {
        if let key = existingKey() { return key }
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
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            return nil
        }
        return key
    }

    private static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
