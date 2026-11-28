import SwiftUI
import UIKit
import Combine
import UserNotifications
import RichManCore

extension Notification.Name {
    /// Posted by Settings → アカウントを消去. RootView performs the wipe so the
    /// onboarding gate flips in one place.
    static let richManWipeAccount = Notification.Name("rm.wipeAccount")
}

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

    @StateObject private var store = AppServices.shared.store!
    @StateObject private var profile = ProfileStore()
    @StateObject private var calls = AppServices.shared.calls!
    @StateObject private var lock = LockStore()
    @StateObject private var location = LocationProvider()
    @StateObject private var tor = TorSession()
    @State private var backgroundedAt: Date?
    @State private var privacyCover = false
    @State private var screenCaptured = UIScreen.main.isCaptured
    @State private var lockAfterCall = false
    @State private var notificationChat: NotificationChat?
    @State private var pendingInvite: PendingInvite?
    @State private var showDebugLocationPrimer = false
    @State private var showDebugPrivacyTutorial = false
    @State private var showDebugDuress = false
    @State private var showDebugAddFriend = false
    @State private var showDebugZone = false

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
                    LockScreenView(onWipe: performEmergencyAction)
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

            if calls.phase != .idle {
                CallOverlay()
                    .environmentObject(calls)
                    .zIndex(2)
            }

            if privacyCover || screenCaptured {
                privacyOverlay
            }
        }
        .environmentObject(store)
        .environmentObject(profile)
        .environmentObject(calls)
        .environmentObject(lock)
        .environmentObject(location)
        .environmentObject(tor)
        .tint(RM.primary)
        .onReceive(
            NotificationCenter.default.publisher(for: .richManWipeAccount)
        ) { _ in
            wipeLocalData()
        }
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
                startEventChannelIfDirect()
                store.prewarmInvite(using: tor.readyTransport)
            }
            wireCalls()
            if let avatar = profile.avatar,
               !UserDefaults.standard.bool(forKey: "rm.avatarPublished") {
                store.updateAvatar(avatar)
            }
            AppServices.shared.register(tor: tor, lock: lock)
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
            if UserDefaults.standard.bool(forKey: "rm.addFriend") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    showDebugAddFriend = true
                }
            }
            if UserDefaults.standard.bool(forKey: "rm.zone") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    showDebugZone = true
                }
            }
            if UserDefaults.standard.string(forKey: "rm.call") == "active" {
                calls.debugActivate()
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                privacyCover = false
                if let at = backgroundedAt, autoLockSeconds > 0,
                   Date().timeIntervalSince(at) >= Double(autoLockSeconds) {
                    if calls.phase == .idle {
                        lock.lock()
                    } else {
                        lockAfterCall = true
                    }
                }
                backgroundedAt = nil
                location.startIfAuthorized()
                if lock.locked {
                    store.attachRelayFactory(nil)
                } else {
                    store.attachRelayFactory(tor.readyTransportFactory)
                startEventChannelIfDirect()
                }
                // The relay keeps push mappings in memory; a relay restart
                // (or a missed launch) must not leave lock-screen calls dead.
                registerPushIfPossible()
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
        .onReceive(
            NotificationCenter.default.publisher(for: .rmVoIPToken)
        ) { note in
            guard let token = note.object as? String, !token.isEmpty else { return }
            store.registerVoIPPush(token: token)
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
        .sheet(isPresented: $showDebugAddFriend) {
            AddFriendView()
                .environmentObject(store)
                .environmentObject(tor)
        }
        .sheet(isPresented: $showDebugZone) {
            ZoneEditorView(zone: nil)
                .environmentObject(tor)
                .environmentObject(location)
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
                startEventChannelIfDirect()
                registerPushIfPossible()
                if let avatar = profile.avatar,
                   !UserDefaults.standard.bool(forKey: "rm.avatarPublished") {
                    store.updateAvatar(avatar)
                }
            }
        }
        .onChange(of: calls.phase) { _, phase in
            if phase == .idle, lockAfterCall {
                lockAfterCall = false
                if !lock.locked { lock.lock() }
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
                startEventChannelIfDirect()
                store.prewarmInvite(using: tor.readyTransport)
                registerPushIfPossible()
            }
        }
        .task {
            #if DEBUG
            await E2E.runIfRequested(store: store, tor: tor)
            #endif
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
    /// Call signalling/audio are wired once in AppServices so a PushKit launch
    /// works before this view exists; only the location probe hook is UI-local.
    private func wireCalls() {
        AppServices.shared.bootstrap()
        store.avatarProvider = { [weak profile] in profile?.avatar }
        store.probeProvider = { [weak location] in
            guard let fix = location?.location else { return nil }
            return (
                fix.coordinate.latitude,
                fix.coordinate.longitude,
                fix.horizontalAccuracy
            )
        }
    }

    private func startEventChannelIfDirect() {
        if !tor.useTor, let url = TorSession.directEventURL {
            store.startEventChannel(url: url)
        } else {
            store.stopEventChannel()
        }
    }

    private func registerPushIfPossible() {
        if let token = UserDefaults.standard.string(forKey: "rm.pushToken"),
           !token.isEmpty {
            store.registerPush(token: token)
        }
        if let voip = UserDefaults.standard.string(forKey: "rm.voipToken"),
           !voip.isEmpty {
            store.registerVoIPPush(token: voip)
        }
    }

    private func wipeLocalData() {
        store.recreateAccount(displayName: "")
        MediaStore.clearAll()
        MediaStore.clearExports()
        profile.removeAvatar()
        TorSession.wipeStorage()
        PrivacyStorage.wipeCaches()
        lock.reset()
        SecurityZoneStore.wipe()
        PrivacyStorage.prepare()
        clearLocalPreferences()
        savedName = ""
        onboarded = false
    }

    /// Remove every local preference that could describe the user.
    private func clearLocalPreferences() {
        let defaults = UserDefaults.standard
        let keys = [
            "rm.onboarded", "rm.displayName", "rm.zoneWanted",
            "rm.preview", "rm.autoLockSeconds", "rm.retentionDays",
            "rm.shareLocation", "rm.wipeAfter",
            "rm.lock.attempts", "rm.lock.pinLength", "rm.lock.duressLength",
            "rm.blocked", "rm.muted", "rm.hidden",
            "rm.duress.chats", "rm.duress.friends", "rm.duress.account",
            "rm.privacyTutorialSeen",
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
    }

    /// Emergency passcode: apply the actions toggled in Settings → セキュリティ.
    private func performEmergencyAction() {
        let defaults = UserDefaults.standard
        let recreate = defaults.object(forKey: "rm.duress.account") as? Bool ?? true
        let friends = defaults.object(forKey: "rm.duress.friends") as? Bool ?? true
        let chats = defaults.object(forKey: "rm.duress.chats") as? Bool ?? true

        if recreate {
            // A brand-new identity with a random name, immediately usable:
            // no relaunch notice and no onboarding. The app looks as if this
            // account existed from the start.
            let name = Self.randomDisplayName()
            store.recreateAccount(displayName: name)
            MediaStore.clearExports()
            profile.removeAvatar()
            MediaStore.clearAll()
            PrivacyStorage.wipeCaches()
            PrivacyStorage.prepare()
            lock.reset()
            SecurityZoneStore.wipe()
            clearLocalPreferences()
            savedName = name
            onboarded = true
            store.attachRelayFactory(tor.readyTransportFactory)
                startEventChannelIfDirect()
            return
        }
        if friends {
            store.clearAllContacts()
            MediaStore.clearAll()
            MediaStore.clearExports()
            PrivacyStorage.wipeCaches()
        } else if chats {
            store.clearAllMessages()
            MediaStore.clearAll()
            MediaStore.clearExports()
            PrivacyStorage.wipeCaches()
        } else {
            // Never leave the emergency code inert: fall back to a full reset.
            let name = Self.randomDisplayName()
            store.recreateAccount(displayName: name)
            MediaStore.clearExports()
            profile.removeAvatar()
            MediaStore.clearAll()
            PrivacyStorage.wipeCaches()
            PrivacyStorage.prepare()
            lock.reset()
            SecurityZoneStore.wipe()
            clearLocalPreferences()
            savedName = name
            onboarded = true
            store.attachRelayFactory(tor.readyTransportFactory)
                startEventChannelIfDirect()
        }
    }

    private static func randomDisplayName() -> String {
        let bases = ["ゲスト", "ユーザー", "名無し", "匿名", "通りすがり"]
        let base = bases.randomElement() ?? "ゲスト"
        return "\(base)\(Int.random(in: 100...999))"
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
