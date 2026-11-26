import Foundation
import UIKit
import UserNotifications

/// Local notifications plus content-free APNs wakeups. Message previews respect
/// the "通知に本文を表示" setting; the relay never sees notification content.
final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Register for APNs when permission was already granted on a previous run.
    func registerIfAuthorized() {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func message(from name: String, preview: String?, peerId: String? = nil) {
        let content = UNMutableNotificationContent()
        let showPreview = UserDefaults.standard.bool(forKey: "rm.preview")
        content.title = showPreview ? name : "RichMan"
        content.body = showPreview ? (preview ?? "新しいメッセージ") : "新しいメッセージ"
        content.sound = .default
        if let peerId { content.userInfo["peer"] = peerId }
        add(content)
    }

    func incomingCall(from name: String) {
        let content = UNMutableNotificationContent()
        let showPreview = UserDefaults.standard.bool(forKey: "rm.preview")
        content.title = "着信"
        content.body = showPreview ? "\(name) さんから着信" : "着信があります"
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        add(content)
    }

    private func add(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
