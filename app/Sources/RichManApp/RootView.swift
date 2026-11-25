import SwiftUI
import UIKit
import Combine
import UserNotifications

/// Gate: first launch → onboarding; afterwards → the hub. The single `ChatStore`
/// is created here and shared with every screen.
struct RootView: View {
    @AppStorage("rm.onboarded") private var onboarded = false
    @AppStorage("rm.displayName") private var savedName = ""
    @AppStorage("rm.autoLockSeconds") private var autoLockSeconds = 0
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var store = ChatStore(displayName: "自分")
    @StateObject private var calls = CallStore()
    @StateObject private var lock = LockStore()
    @StateObject private var location = LocationProvider()
    @StateObject private var tor = TorSession()
    @State private var backgroundedAt: Date?
    @State private var privacyCover = false
    @State private var screenCaptured = UIScreen.main.isCaptured

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
        ZStack {
            Group {
                if lock.locked {
                    LockScreenView(onWipe: wipeLocalData)
                } else if let gid = debugGroupId, let group = store.group(gid) {
                    NavigationStack { GroupChatView(group: group) }
                } else if let peer = debugChatPeer, let contact = store.contact(peer) {
                    NavigationStack { ChatView(contact: contact) }
                } else if onboarded || skipOnboarding {
                    HubView()
                } else {
                    OnboardingView()
                }
            }

            if privacyCover || screenCaptured {
                privacyOverlay
            }
        }
        .environmentObject(store)
        .environmentObject(calls)
        .environmentObject(lock)
        .environmentObject(location)
        .environmentObject(tor)
        .tint(RM.primary)
        .onAppear {
            if !savedName.isEmpty { store.displayName = savedName }
            #if DEBUG
            if skipOnboarding, savedName.isEmpty { store.displayName = "テスト" }
            SecurityZoneStore.seedDebugZoneIfNeeded()
            #endif
            location.startIfAuthorized()
            applySecurityZoneIfNeeded()
            // No-op in the mock build (TorSupport not linked).
            tor.start()
            wireCalls()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                privacyCover = false
                if let at = backgroundedAt, autoLockSeconds > 0,
                   Date().timeIntervalSince(at) >= Double(autoLockSeconds) {
                    lock.lock()
                }
                backgroundedAt = nil
                location.startIfAuthorized()
                store.attachRelay(tor.readyTransport)
                applySecurityZoneIfNeeded()
            case .background:
                privacyCover = true
                backgroundedAt = Date()
                store.attachRelay(nil)
            case .inactive:
                privacyCover = true
            @unknown default:
                break
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)
        ) { _ in
            screenCaptured = UIScreen.main.isCaptured
        }
        .onChange(of: location.location?.timestamp) { _, _ in
            if scenePhase == .active { applySecurityZoneIfNeeded() }
        }
        .onChange(of: tor.phase) { _, _ in
            // Tor becomes usable some seconds after launch; attach then so the
            // send/receive loop only runs over a live circuit. (The background
            // transition detaches again, so this cannot poll while hidden.)
            store.attachRelay(tor.readyTransport)
        }
        .task {
            #if DEBUG
            await E2E.runIfRequested(store: store, tor: tor)
            #endif
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { calls.phase != .idle },
                set: { if !$0 { calls.end() } }
            )
        ) {
            CallOverlay().environmentObject(calls)
        }
    }

    /// Hides content in the app switcher and while the screen is being recorded.
    private var privacyOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(RM.primary)
                Text(screenCaptured ? "画面収録中" : "RichMan")
                    .font(.headline)
                if screenCaptured {
                    Text("録画中は内容を表示しません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .transition(.opacity)
        .zIndex(10)
    }

    /// Local wipe after repeated wrong PINs. Remote copies are unaffected.
    /// Call signaling and ADPCM audio ride the same encrypted 1:1 path as
    /// messages; the call layer only gets the store's transport hooks.
    private func wireCalls() {
        store.onCallSignal = { [weak calls] peer, signal in
            calls?.handleSignal(from: peer, signal: signal)
        }
        store.onCallAudio = { [weak calls] peer, packet in
            calls?.handleAudio(from: peer, packet: packet)
        }
        calls.sendPayload = { [weak store] peer, data in
            store?.sendCallPayload(data, to: peer)
        }
        calls.onFastPolling = { [weak store] on, peer in
            store?.setFastPolling(on, peerId: peer)
        }
        calls.nameResolver = { [weak store] peer in
            store?.contact(peer)?.name
        }
    }

    private func wipeLocalData() {
        store.wipeAllLocal()
        MediaStore.clearAll()
        lock.reset()
        UserDefaults.standard.set(false, forKey: "rm.onboarded")
        UserDefaults.standard.removeObject(forKey: "rm.displayName")
        savedName = ""
    }

    /// Applies the security-zone action when the user is inside the zone.
    private func applySecurityZoneIfNeeded() {
        guard let zone = SecurityZoneStore.current,
              let fix = location.location,
              zone.contains(fix.coordinate) else { return }
        switch zone.action {
        case .lock:
            lock.lock()
        case .clearChats:
            store.clearAllMessages()
        case .clearAccount:
            wipeLocalData()
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
    @EnvironmentObject private var store: ChatStore

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
            MapHomeView()
                .tabItem { Label("マップ", systemImage: "map.fill") }
                .tag(0)
            TalksView()
                .tabItem { Label("トーク", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(store.totalUnread)
                .tag(1)
            FriendsView()
                .tabItem { Label("友だち", systemImage: "person.2.fill") }
                .tag(2)
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .onChange(of: store.totalUnread) { _, count in
            UNUserNotificationCenter.current().setBadgeCount(
                count,
                withCompletionHandler: nil
            )
        }
    }
}
