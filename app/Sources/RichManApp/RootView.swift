import SwiftUI

/// Gate: first launch → onboarding; afterwards → the hub. The single `ChatStore`
/// is created here and shared with every screen.
struct RootView: View {
    @AppStorage("rm.onboarded") private var onboarded = false
    @AppStorage("rm.displayName") private var savedName = ""
    @StateObject private var store = ChatStore(displayName: "自分")

    var body: some View {
        Group {
            if onboarded {
                HubView()
            } else {
                OnboardingView()
            }
        }
        .environmentObject(store)
        .tint(RM.primary)
        .onAppear { if !savedName.isEmpty { store.displayName = savedName } }
    }
}

/// The hub tabs, matching the Android app: トーク / 友だち / 設定.
struct HubView: View {
    var body: some View {
        TabView {
            TalksView()
                .tabItem { Label("トーク", systemImage: "bubble.left.and.bubble.right.fill") }
            FriendsView()
                .tabItem { Label("友だち", systemImage: "person.2.fill") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
        }
    }
}
