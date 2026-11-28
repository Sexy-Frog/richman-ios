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
        if FreshInstall.resetIfNeeded() {
            FreshInstall.bindDeviceIfNeeded()
        }
        // Exclude Application Support from backups as early as possible; new
        // files inherit the excluded directory.
        PrivacyStorage.prepare()
        // Create the shared stores before any view, so a PushKit launch can
        // decrypt the call offer without a visible scene.
        AppServices.shared.bootstrap()
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
