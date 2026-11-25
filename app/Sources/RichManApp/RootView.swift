import SwiftUI

/// The hub shell, matching the Android app: トーク / 友だち / 設定.
struct RootView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        TabView {
            TalksView()
                .tabItem { Label("トーク", systemImage: "bubble.left.and.bubble.right.fill") }
            FriendsView()
                .tabItem { Label("友だち", systemImage: "person.2.fill") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
        }
        .environmentObject(model)
    }
}

/// Top-level app state. Holds the crypto boundary (mock in Simulator, real
/// libsignal on device) and will own the chat/relay controllers as they land.
final class AppModel: ObservableObject {
    @Published var displayName: String = "自分"
    let crypto: CryptoProvider

    init(crypto: CryptoProvider = MockCryptoProvider()) {
        self.crypto = crypto
    }
}
