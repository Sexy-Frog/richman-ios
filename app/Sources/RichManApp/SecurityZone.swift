import Foundation
import CoreLocation

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

enum SecurityZoneStore {
    private static let key = "rm.securityZone"

    static var current: SecurityZone? {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(SecurityZone.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
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
