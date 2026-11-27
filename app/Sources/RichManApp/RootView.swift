import SwiftUI
import UIKit
import Combine
import UserNotifications
import RichManCore

private struct NotificationChat: Identifiable {
    let id: String
}

private struct PendingInvite: Identifiable {
    let id = UUID()
    let raw: String
}

/// Gate: first launch → onboarding; afterwards → the hub. The single `ChatStore`
/// is created here and shared with every screen.
struct RootView: View {
    @AppStorage("rm.onboarded") private var onboarded = false
    @AppStorage("rm.displayName") private var savedName = ""
    @AppStorage("rm.autoLockSeconds") private var autoLockSeconds = 30
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var store = ChatStore(displayName: "自分")
    @StateObject private var calls = CallStore()
    @StateObject private var lock = LockStore()
    @StateObject private var location = LocationProvider()
    @StateObject private var tor = TorSession()
    @State private var backgroundedAt: Date?
    @State private var privacyCover = false
    @State private var screenCaptured = UIScreen.main.isCaptured
    @State private var notificationChat: NotificationChat?
    @State private var pendingInvite: PendingInvite?
    @State private var showDebugLocationPrimer = false
    @State private var showDebugPrivacyTutorial = false
    @State private var showDebugDuress = false

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
            // No-op in the mock build (TorSupport not linked). With an external
            // SOCKS (CI) the phase is ready synchronously, so attach here too;
            // otherwise the onChange below attaches when Tor bootstraps.
            tor.start()
            if lock.locked {
                store.suspendSensitiveState()
                store.attachRelayFactory(nil)
            } else {
                store.attachRelayFactory(tor.readyTransportFactory)
            }
            wireCalls()
            AppServices.shared.register(store: store, tor: tor, lock: lock)
            registerPushIfPossible()
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "rm.locationPrimer") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    showDebugLocationPrimer = true
                }
            }
            if UserDefaults.standard.bool(forKey: "rm.privacyTutorial") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    showDebugPrivacyTutorial = true
                }
            }
            if UserDefaults.standard.bool(forKey: "rm.showDuress") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    showDebugDuress = true
                }
            }
            #endif
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
                if lock.locked {
                    store.attachRelayFactory(nil)
                } else {
                    store.attachRelayFactory(tor.readyTransportFactory)
                }
                applySecurityZoneIfNeeded()
            case .background:
                privacyCover = true
                backgroundedAt = Date()
                store.attachRelayFactory(nil)
                PrivacyStorage.wipeCaches()
                AppServices.shared.scheduleRefresh()
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
        .onReceive(
            NotificationCenter.default.publisher(for: .rmOpenChat)
        ) { note in
            guard !lock.locked,
                  let peer = note.object as? String,
                  store.contact(peer) != nil else { return }
            notificationChat = NotificationChat(id: peer)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .rmPushToken)
        ) { note in
            guard let token = note.object as? String, !token.isEmpty else { return }
            store.registerPush(token: token)
        }
        .onOpenURL { url in
            if let raw = InviteLink.normalize(url.absoluteString) {
                pendingInvite = PendingInvite(raw: raw)
            }
        }
        .onChange(of: store.contacts.count) { _, _ in
            registerPushIfPossible()
        }
        .sheet(item: $notificationChat) { target in
            if let contact = store.contact(target.id) {
                NavigationStack { ChatView(contact: contact) }
                    .environmentObject(store)
                    .environmentObject(calls)
                    .environmentObject(location)
                    .environmentObject(tor)
            }
        }
        .sheet(item: Binding(
            get: { (lock.locked || !onboarded) ? nil : pendingInvite },
            set: { pendingInvite = $0 }
        )) { invite in
            AddFriendView(initialCode: invite.raw)
                .environmentObject(store)
                .environmentObject(tor)
        }
        .sheet(isPresented: $showDebugLocationPrimer) {
            LocationPrimer().environmentObject(location)
        }
        .sheet(isPresented: $showDebugPrivacyTutorial) {
            PrivacyTutorialSheet()
        }
        .sheet(isPresented: $showDebugDuress) {
            DuressView().environmentObject(lock)
        }
        .onChange(of: location.location?.timestamp) { _, _ in
            if scenePhase == .active { applySecurityZoneIfNeeded() }
        }
        .onChange(of: lock.locked) { _, locked in
            if locked {
                store.suspendSensitiveState()
                store.attachRelayFactory(nil)
                MediaStore.clearExports()
                PrivacyStorage.wipeCaches()
            } else {
                store.restoreSensitiveState()
                store.attachRelayFactory(tor.readyTransportFactory)
                registerPushIfPossible()
            }
        }
        .onChange(of: tor.phase) { _, _ in
            // Tor becomes usable some seconds after launch; attach then so the
            // send/receive loop only runs over a live circuit. (The background
            // transition detaches again, so this cannot poll while hidden.)
            if lock.locked {
                store.attachRelayFactory(nil)
            } else {
                store.attachRelayFactory(tor.readyTransportFactory)
                registerPushIfPossible()
            }
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
                .fill(Color(.systemBackground))
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
        store.probeProvider = { [weak location] in
            guard let fix = location?.location else { return nil }
            return (
                fix.coordinate.latitude,
                fix.coordinate.longitude,
                fix.horizontalAccuracy
            )
        }
    }

    private func registerPushIfPossible() {
        guard let token = UserDefaults.standard.string(forKey: "rm.pushToken"),
              !token.isEmpty else { return }
        store.registerPush(token: token)
    }

    private func wipeLocalData() {        store.wipeAllLocal()
        MediaStore.clearAll()
        MediaStore.clearExports()
        TorSession.wipeStorage()
        PrivacyStorage.wipeCaches()
        lock.reset()
        SecurityZoneStore.wipe()
        PrivacyStorage.prepare()

        // Remove every local preference that could describe the user, not just
        // the chat state. This is also what the emergency passcode promises.
        let defaults = UserDefaults.standard
        let keys = [
            "rm.onboarded", "rm.displayName", "rm.zoneWanted",
            "rm.preview", "rm.autoLockSeconds", "rm.retentionDays",
            "rm.shareLocation", "rm.wipeAfter",
            "rm.lock.attempts", "rm.lock.pinLength", "rm.lock.duressLength",
            "rm.blocked",
        ]
        for key in keys { defaults.removeObject(forKey: key) }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("rm.ttl.") {
            defaults.removeObject(forKey: key)
        }

        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0, withCompletionHandler: nil)
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
        // No map tab (Android parity): the map is presented on demand from
        // location-check answers, location bubbles, or the menu.
        TabView(selection: $tab) {
            TalksView()
                .tabItem { Label("トーク", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(store.totalUnread)
                .tag(0)
            FriendsView()
                .tabItem { Label("友だち", systemImage: "person.2.fill") }
                .tag(1)
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .onChange(of: store.totalUnread) { _, count in
            UNUserNotificationCenter.current().setBadgeCount(
                count,
                withCompletionHandler: nil
            )
        }
    }
}
