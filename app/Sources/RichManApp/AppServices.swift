import Foundation
import BackgroundTasks

/// Small app-level rendezvous for the SwiftUI background refresh task. The
/// RootView owns the stores; this object only keeps weak references so the BG
/// task can poll the relay once while the app is in the background.
final class AppServices {
    static let shared = AppServices()

    private weak var store: ChatStore?
    private weak var tor: TorSession?
    private weak var lock: LockStore?

    @MainActor
    func register(store: ChatStore, tor: TorSession, lock: LockStore) {
        self.store = store
        self.tor = tor
        self.lock = lock
    }

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

    /// Attach the Tor transport, poll every mailbox once, then detach. Polling
    /// is driven explicitly here so the regular 5-second loop never starts in
    /// the background.
    @MainActor
    func pollInBackground() async {
        guard let store, let tor, lock?.locked == false else { return }

        // A suspended app keeps its Tor daemon; a cold background launch may
        // not have started it. Give bootstrap a short, bounded window.
        if tor.phase == .stopped { tor.start() }
        if tor.phase == .starting {
            for _ in 0..<20 where tor.phase == .starting {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard let factory = tor.readyTransportFactory else {
            scheduleRefresh()
            return
        }

        store.attachRelayFactory(factory, startPolling: false)
        await store.pollOnce()
        store.attachRelayFactory(nil, startPolling: false)
        scheduleRefresh()
    }
}

enum BackgroundRefresh {
    static let identifier = "works.kelvins.richman.refresh"
}
