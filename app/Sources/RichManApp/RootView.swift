import SwiftUI

/// Gate: first launch → onboarding; afterwards → the hub. The single `ChatStore`
/// is created here and shared with every screen.
struct RootView: View {
    @AppStorage("rm.onboarded") private var onboarded = false
    @AppStorage("rm.displayName") private var savedName = ""
    @StateObject private var store = ChatStore(displayName: "自分")

    /// Screenshot/CI hook: launch with `-rm.skipOnboarding 1` to bypass setup.
    /// DEBUG only, so release builds always start at onboarding.
    private var skipOnboarding: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "rm.skipOnboarding")
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if let gid = debugGroupId, let group = store.group(gid) {
                NavigationStack { GroupChatView(group: group) }
            } else if let peer = debugChatPeer, let contact = store.contact(peer) {
                NavigationStack { ChatView(contact: contact) }
            } else if onboarded || skipOnboarding {
                HubView()
            } else {
                OnboardingView()
            }
        }
        .environmentObject(store)
        .tint(RM.primary)
        .onAppear {
            if !savedName.isEmpty { store.displayName = savedName }
            #if DEBUG
            if skipOnboarding, savedName.isEmpty { store.displayName = "テスト" }
            #endif
        }
    }

    /// Screenshot/CI hook: `-rm.chat <peerId>` opens that conversation directly.
    private var debugChatPeer: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "rm.chat")
        #else
        return nil
        #endif
    }

    /// Screenshot/CI hook: `-rm.group <gid>` opens that group conversation.
    private var debugGroupId: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "rm.group")
        #else
        return nil
        #endif
    }
}

/// The hub tabs, matching the Android app: トーク / 友だち / 設定.
struct HubView: View {
    /// Screenshot/CI hook: `-rm.tab 2` opens 設定 directly (DEBUG only).
    @State private var tab: Int = {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "rm.tab")
        #else
        return 0
        #endif
    }()

    var body: some View {
        TabView(selection: $tab) {
            TalksView()
                .tabItem { Label("トーク", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(0)
            FriendsView()
                .tabItem { Label("友だち", systemImage: "person.2.fill") }
                .tag(1)
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(2)
        }
    }
}
