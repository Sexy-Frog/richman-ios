import UIKit
import UserNotifications

/// Shows banners while the app is in the foreground; background delivery is
/// handled by the system once permission is granted.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PrivacyStorage.prepare()
        MediaStore.clearExports()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tapping a message notification opens that conversation.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let peer = response.notification.request.content
            .userInfo["peer"] as? String else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .rmOpenChat, object: peer)
        }
    }
}

extension Notification.Name {
    static let rmOpenChat = Notification.Name("rm.openChat")
}
