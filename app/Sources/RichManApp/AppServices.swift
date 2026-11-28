import Foundation
import UIKit
import BackgroundTasks
import RichManCore

/// Small app-level rendezvous for the shared stores, the background refresh
/// task, and PushKit call wakeups. It is created once at launch so a VoIP push
/// can fetch/decrypt an offer even when no SwiftUI scene is on screen.
final class AppServices {
    static let shared = AppServices()

    private(set) var store: ChatStore!
    private(set) var calls: CallStore!
    private weak var tor: TorSession?
    private weak var lock: LockStore?
    private var wired = false
    private var cachedDirect: DirectTransport?

    private init() {}

    /// Must run on the main thread and before the first view is created.
    /// Safe to call again; later calls only refresh the Tor/lock references.
    func bootstrap() {
        MainActor.assumeIsolated {
            if store == nil {
                store = ChatStore(displayName: "自分")
            }
            if calls == nil {
                calls = CallStore()
            }
            wireCallLayer()
        }
    }

    @MainActor
    func register(tor: TorSession, lock: LockStore) {
        self.tor = tor
        self.lock = lock
    }

    @MainActor
    private func wireCallLayer() {
        guard !wired else { return }
        wired = true
        let store = store!
        let calls = calls!
        calls.sendPayload = { [weak store] peer, data, silent, voip, done in
            store?.sendCallPayload(
                data, to: peer, silent: silent, voip: voip, completion: done
            )
        }
        calls.onFastPolling = { [weak store] on, peer in
            store?.setFastPolling(on, peerId: peer)
        }
        calls.onCallEnded = { [weak store] peer, seconds, outgoing, missed in
            store?.appendCallRecord(
                peerId: peer,
                seconds: seconds,
                outgoing: outgoing,
                missed: missed
            )
        }
        calls.nameResolver = { [weak store] peer in
            store?.contact(peer)?.name
        }
        calls.onCallFinished = { [weak self] in
            CallKitManager.shared.callEnded()
            // The call kept the receive loop alive in the background; stop it
            // again once the call is over.
            if UIApplication.shared.applicationState != .active {
                self?.store.attachRelayFactory(nil, startPolling: false)
            }
        }
        store.onCallSignal = { [weak calls] peer, signal in
            calls?.handleSignal(from: peer, signal: signal)
        }
        store.onCallAudio = { [weak calls] peer, packet in
            calls?.handleAudio(from: peer, packet: packet)
        }
    }

    // MARK: background

    /// Ask iOS for an opportunistic background refresh. This is best-effort:
    /// iOS decides when/if it runs, and a force-quit app never gets one.
    @MainActor
    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(
            identifier: BackgroundRefresh.identifier
        )
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Attach the transport, poll every mailbox once, then detach. Polling is
    /// driven explicitly here so the regular receive loop never starts in the
    /// background.
    @MainActor
    func pollInBackground() async {
        guard let store, lock?.locked == false else { return }
        guard let factory = transportFactory() else {
            scheduleRefresh()
            return
        }
        store.attachRelayFactory(factory, startPolling: false)
        await store.pollOnce()
        if calls?.phase == .idle {
            store.attachRelayFactory(nil, startPolling: false)
        }
        scheduleRefresh()
    }

    /// PushKit woke us for a call. Keep the transport attached so the answer /
    /// decline can be sent, but never start the receive loop while backgrounded.
    @MainActor
    func handleVoIPCall(box: String?) async {
        guard store != nil else { return }
        guard let factory = transportFactory() else { return }
        if !store.relayReady {
            store.attachRelayFactory(factory, startPolling: false)
        }
        if let box, !box.isEmpty {
            await store.pollBox(box)
        } else {
            await store.pollOnce()
        }
    }

    /// Direct HTTPS unless the user opted into the high-anonymity Tor path.
    /// In Tor mode a terminated/background launch cannot bootstrap Tor here;
    /// CallKit still rings and the offer is fetched once the app is opened.
    @MainActor
    private func transportFactory() -> (@Sendable (String) -> RelayTransport)? {
        let useTor = UserDefaults.standard.object(forKey: "rm.useTor") as? Bool ?? false
        if useTor {
            return tor?.readyTransportFactory
        }
        if let cachedDirect {
            return { _ in cachedDirect }
        }
        guard let url = TorSession.directRelayURL else { return nil }
        let transport = DirectTransport(baseURL: url)
        cachedDirect = transport
        return { _ in transport }
    }
}

enum BackgroundRefresh {
    static let identifier = "works.kelvins.richman.refresh"
}
