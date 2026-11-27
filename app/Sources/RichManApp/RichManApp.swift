import SwiftUI

/// App entry. The whole UI is ported from the native Android client (hub model:
/// トーク / 友だち / 設定, Signal-blue). The protocol underneath is the native
/// RichManCore (Wire v2 / relay) + RichManCrypto (libsignal) stack; crypto is
/// reached only through `CryptoProvider` so the UI builds in the Simulator
/// without the FFI.
@main
struct RichManApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // A reinstall keeps Keychain items (PIN, zone/store keys); clear them
        // when UserDefaults shows this is a fresh install.
        FreshInstall.resetIfNeeded()
        // A full wipe needs a fresh process before a new identity is created,
        // so clear the "restart required" gate at launch.
        UserDefaults.standard.removeObject(forKey: "rm.needsRelaunch")
        // Exclude Application Support from backups as early as possible; new
        // files inherit the excluded directory.
        PrivacyStorage.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(RM.primary)
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await AppServices.shared.pollInBackground()
        }
    }
}
