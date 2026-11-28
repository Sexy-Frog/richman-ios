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
        AppServices.shared.bootstrap()
        MainActor.assumeIsolated {
            CallKitManager.shared.start()
        }
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.shared.registerIfAuthorized()
        return true
    }

    /// Content-free APNs token. It is sent to the relay over the selected
    /// transport (direct HTTPS by default) so the relay can wake this device
    /// with "new message" only (no sender/content). Calls use a separate
    /// PushKit token registered by CallKitManager.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "rm.pushToken")
        UserDefaults.standard.removeObject(forKey: "rm.pushError")
        NotificationCenter.default.post(name: .rmPushToken, object: token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        UserDefaults.standard.set(
            error.localizedDescription,
            forKey: "rm.pushError"
        )
        #if DEBUG
        NSLog("APNs registration failed: %@", String(describing: error))
        #endif
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A call alert is only a fallback when PushKit is unavailable. If the
        // in-app call screen is already handling it, do not show a second banner.
        if (notification.request.content.userInfo["call"] as? Int) == 1,
           AppServices.shared.calls?.phase != .idle {
            return []
        }
        return [.banner, .sound]
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
