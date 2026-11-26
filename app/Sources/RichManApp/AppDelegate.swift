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
        NotificationManager.shared.registerIfAuthorized()
        return true
    }

    /// Content-free APNs token. It is sent to the relay over Tor so the relay can
    /// wake this device with "new message" only (no sender/content).
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "rm.pushToken")
        NotificationCenter.default.post(name: .rmPushToken, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        NSLog("APNs registration failed: %@", String(describing: error))
        #endif
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
    static let rmPushToken = Notification.Name("rm.pushToken")
}
