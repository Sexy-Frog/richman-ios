import Foundation
import CoreLocation
import CryptoKit
import Security

/// A circular zone with an action applied when the user is inside it.
struct SecurityZone: Codable, Equatable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case lock
        case clearChats
        case clearAccount

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lock: return "ロックする"
            case .clearChats: return "トークを全部消す"
            case .clearAccount: return "アカウントを消す"
            }
        }
    }

    var latitude: Double
    var longitude: Double
    var radius: Double
    var action: Action

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let zone = CLLocation(latitude: latitude, longitude: longitude)
        let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return zone.distance(from: point) <= radius
    }
}

/// Stores the privacy-zone centre/radius/action. Android seals these because
/// the places a user marks are themselves sensitive; iOS does the same here.
/// The ciphertext may live in UserDefaults (and therefore a backup), but the
/// AES-GCM key is a device-only Keychain item, so a restored/backed-up blob is
/// useless. Legacy plaintext is migrated and deleted on first read.
enum SecurityZoneStore {
    private static let sealedKey = "rm.securityZone.sealed"
    private static let legacyKey = "rm.securityZone"
    private static let service = "works.kelvins.richman.zone"
    private static let account = "zone-key"
    private static let marker = Data([0x52, 0x4D, 0x5A, 0x4E, 0x01]) // RMZN v1

    static var current: SecurityZone? {
        get {
            if let sealed = UserDefaults.standard.data(forKey: sealedKey),
               let plain = open(sealed),
               let zone = try? JSONDecoder().decode(SecurityZone.self, from: plain) {
                return zone
            }
            // One-time migration from the old plaintext representation.
            if let data = UserDefaults.standard.data(forKey: legacyKey),
               let zone = try? JSONDecoder().decode(SecurityZone.self, from: data) {
                current = zone
                return zone
            }
            return nil
        }
        set {
            guard let newValue,
                  let plain = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: sealedKey)
                UserDefaults.standard.removeObject(forKey: legacyKey)
                return
            }
            if let sealed = seal(plain) {
                UserDefaults.standard.set(sealed, forKey: sealedKey)
                UserDefaults.standard.removeObject(forKey: legacyKey)
            } else {
                #if DEBUG
                // Unsigned Simulator/demo builds may not have a Keychain.
                UserDefaults.standard.removeObject(forKey: sealedKey)
                UserDefaults.standard.set(plain, forKey: legacyKey)
                #else
                UserDefaults.standard.removeObject(forKey: sealedKey)
                UserDefaults.standard.removeObject(forKey: legacyKey)
                #endif
            }
        }
    }

    /// Remove the zone and its Keychain key (panic wipe / emergency code).
    static func wipe() {
        UserDefaults.standard.removeObject(forKey: sealedKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        deleteKey()
    }

    // MARK: sealing

    private static func seal(_ data: Data) -> Data? {
        guard let key = loadOrCreateKey(),
              let box = try? AES.GCM.seal(data, using: key),
              let combined = box.combined else { return nil }
        var out = marker
        out.append(combined)
        return out
    }

    private static func open(_ data: Data) -> Data? {
        guard data.count > marker.count,
              data.prefix(marker.count) == marker,
              let key = loadKey(),
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst(marker.count)) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key)
    }

    private static func loadOrCreateKey() -> SymmetricKey? {
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

    private static func loadKey() -> SymmetricKey? {
        guard let data = loadKeyData() else { return nil }
        return SymmetricKey(data: data)
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

    private static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    #if DEBUG
    /// Screenshot/demo hook: `-rm.zone lock` seeds a zone around Tokyo Station.
    static func seedDebugZoneIfNeeded() {
        guard let kind = UserDefaults.standard.string(forKey: "rm.zone"),
              current == nil else { return }
        let action: SecurityZone.Action = kind == "chats" ? .clearChats : .lock
        current = SecurityZone(
            latitude: 35.6812,
            longitude: 139.7671,
            radius: 500,
            action: action
        )
    }
    #endif
}
