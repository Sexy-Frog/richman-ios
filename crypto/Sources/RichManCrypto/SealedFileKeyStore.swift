import Foundation
import CryptoKit
import Security
import LibSignalClient

/// Keychain-held AES key for the sealed local store. Destroying this key makes
/// every record unreadable (wipe).
public enum KeychainKey {
    public enum KeyError: Error { case keychain(OSStatus) }

    public static func loadOrCreate(
        service: String = "works.kelvins.richman.signal",
        account: String = "store-key"
    ) throws -> SymmetricKey {
        if let data = load(service: service, account: account) {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try save(data, service: service, account: account)
        return key
    }

    private static func load(service: String, account: String) -> Data? {
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

    /// Destroys the store key so no ciphertext (including backups) can ever be
    /// opened again. Used by the emergency wipe.
    public static func delete(
        service: String = "works.kelvins.richman.signal",
        account: String = "store-key"
    ) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
    }
}

public enum CryptoIdentityFactory {
    public static func generate() -> (identity: Data, registrationId: UInt32) {
        let pair = IdentityKeyPair.generate()
        return (pair.serialize(), UInt32.random(in: 1...16380))
    }
}

/// `KeyStoreBackend` backed by a single SealedBox-encrypted file. All libsignal
/// records and small meta values live in one JSON blob; each mutation re-seals
/// atomically. Small enough for a phone-sized contact list.
public final class SealedFileKeyStore: KeyStoreBackend {
    private let url: URL
    private let box: SealedBox
    private var state: [String: String]
    private let lock = NSLock()

    public init(url: URL, key: SymmetricKey) throws {
        self.url = url
        self.box = SealedBox(key: key)
        if let sealed = try? Data(contentsOf: url),
           let plain = try? box.open(sealed),
           let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: String] {
            state = obj
        } else {
            let generated = CryptoIdentityFactory.generate()
            state = [
                "identity": generated.identity.base64EncodedString(),
                "reg": String(generated.registrationId),
            ]
            try persist(state)
        }
    }

    private func persist(_ snapshot: [String: String]) throws {
        let plain = try JSONSerialization.data(withJSONObject: snapshot)
        let sealed = try box.seal(plain)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try sealed.write(to: url, options: options)
    }

    private func read(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return state[key].flatMap { Data(base64Encoded: $0) }
    }

    private func write(_ key: String, _ value: Data?) {
        lock.lock()
        state[key] = value?.base64EncodedString()
        let snapshot = state
        lock.unlock()
        try? persist(snapshot)
    }

    private func readString(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return state[key]
    }

    private func writeString(_ key: String, _ value: String?) {
        lock.lock()
        state[key] = value
        let snapshot = state
        lock.unlock()
        try? persist(snapshot)
    }

    // MARK: identity

    public func loadIdentityKeyPair() throws -> Data {
        guard let data = read("identity") else { throw CryptoError.identityNotInitialised }
        return data
    }

    public func loadLocalRegistrationId() throws -> UInt32 {
        UInt32(readString("reg") ?? "") ?? 1
    }

    // MARK: peers / sessions

    public func loadPeerIdentity(_ name: String) -> Data? { read("peer:\(name)") }
    public func storePeerIdentity(_ name: String, _ serialized: Data) {
        write("peer:\(name)", serialized)
    }

    public func loadSession(_ name: String, _ device: UInt32) -> Data? {
        read("session:\(name)|\(device)")
    }

    public func storeSession(_ name: String, _ device: UInt32, _ record: Data) {
        write("session:\(name)|\(device)", record)
    }

    public func containsSession(_ name: String, _ device: UInt32) -> Bool {
        read("session:\(name)|\(device)") != nil
    }

    public func deleteSession(_ name: String, _ device: UInt32) {
        write("session:\(name)|\(device)", nil)
    }

    // MARK: prekeys

    public func loadPreKey(_ id: UInt32) -> Data? { read("prekey:\(id)") }
    public func storePreKey(_ id: UInt32, _ record: Data) { write("prekey:\(id)", record) }
    public func removePreKey(_ id: UInt32) { write("prekey:\(id)", nil) }

    public func preKeyCount() -> Int { preKeyIds().count }

    public func preKeyIds() -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return state.keys.compactMap { key in
            guard key.hasPrefix("prekey:") else { return nil }
            return UInt32(key.dropFirst("prekey:".count))
        }
    }

    public func loadSignedPreKey(_ id: UInt32) -> Data? { read("spk:\(id)") }
    public func storeSignedPreKey(_ id: UInt32, _ record: Data) { write("spk:\(id)", record) }

    public func loadKyberPreKey(_ id: UInt32) -> Data? { read("kpk:\(id)") }
    public func storeKyberPreKey(_ id: UInt32, _ record: Data) { write("kpk:\(id)", record) }

    // MARK: meta

    public func meta(_ key: String) -> String? { readString("meta:\(key)") }
    public func setMeta(_ key: String, _ value: String) { writeString("meta:\(key)", value) }
}
