import SwiftUI

/// App entry. The whole UI is ported from the native Android client (hub model:
/// トーク / 友だち / 設定, Signal-blue). The protocol underneath is the native
/// RichManCore (Wire v2 / relay) + RichManCrypto (libsignal) stack; crypto is
/// reached only through `CryptoProvider` so the UI builds in the Simulator
/// without the FFI.
@main
struct RichManApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(RM.primary)
        }
    }
}
