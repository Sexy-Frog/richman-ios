import Foundation
import RichManCore
#if canImport(TorSupport)
import TorSupport
#endif

/// Owns the embedded Tor daemon and the SOCKS transport to the relay. Tor is
/// the only path to the relay: there is no clearnet fallback. In the mock /
/// Simulator build (no TorSupport package linked) this object reports
/// `unsupported` instead of pretending to be online.
@MainActor
final class TorSession: ObservableObject {
    /// The relay's v3 onion address, injected at build time (`RM_RELAY_HOST`)
    /// instead of living in this public repository (docs/DESIGN.md §9).
    static var relayHost: String {
        (Bundle.main.object(forInfoDictionaryKey: "RMRelayHost") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static let relayPort: UInt16 = 80

    enum Phase: Equatable {
        case unsupported
        case stopped
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase
    @Published private(set) var reachable = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?
    /// Loopback style URL once the Tor-backed map proxy is serving.
    @Published private(set) var mapStyleURL: URL?

    private var launcher: AnyObject?
    private var pollTask: Task<Void, Never>?

    init() {
        #if canImport(TorSupport)
        phase = .stopped
        #else
        phase = .unsupported
        #endif
    }

    var supportsTor: Bool {
        #if canImport(TorSupport)
        true
        #else
        false
        #endif
    }

    var statusText: String {
        if supportsTor && !configured { return "リレー未設定" }
        return switch phase {
        case .unsupported: "このビルドでは無効"
        case .stopped: "停止"
        case .starting: "起動中…"
        case .ready: reachable ? "接続済み" : "起動済み（未接続）"
        case .failed(let message): "失敗: \(message)"
        }
    }

    /// Transport for relay calls, and only when Tor has reached the relay.
    var readyTransport: RelayTransport? {
        phase == .ready ? relayTransport : nil
    }

    /// False when the build was produced without a relay address.
    var configured: Bool { !Self.relayHost.isEmpty }

    /// Transport for relay calls, only once the SOCKS listener is up.
    var relayTransport: SOCKS5Transport? {
        guard phase != .unsupported, configured else { return nil }
        return SOCKS5Transport(
            proxy: SOCKS5Address(host: "127.0.0.1", port: 39050),
            targetHost: Self.relayHost,
            targetPort: Self.relayPort,
            username: "default"
        )
    }

    func start() {
        #if canImport(TorSupport)
        guard launcher == nil, configured else { return }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("tor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let config = TorConfig(
            socksPort: 39050,
            dataDirectory: base,
            cacheDirectory: base.appendingPathComponent("cache", isDirectory: true),
            logFile: base.appendingPathComponent("tor.log")
        )
        let launcher = TorLauncher(config: config)
        self.launcher = launcher
        phase = .starting
        guard launcher.start() else {
            phase = .failed("Tor は既に起動しています")
            return
        }
        pollBootstrap()
        #else
        phase = .unsupported
        #endif
    }

    /// Ask Tor for its bootstrap by trying the relay. A v3 onion cannot be
    /// reached until Tor has a working circuit, so a successful `/healthz`
    /// is also a bootstrap-complete signal.
    func checkNow() {
        Task { await check() }
    }

    private func pollBootstrap() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            // Client bootstrap over a slow mobile network can take a while.
            for _ in 0..<90 {
                if Task.isCancelled { return }
                if await self.check() { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if self.phase == .starting {
                self.phase = .failed("Tor の起動がタイムアウトしました")
            }
        }
    }

    @discardableResult
    private func check() async -> Bool {
        guard let transport = relayTransport else { return false }
        let client = RelayClient(transport: transport)
        do {
            let ok = try await client.ping()
            reachable = ok
            lastCheck = Date()
            if ok {
                phase = .ready
                lastError = nil
                if mapStyleURL == nil {
                    // Tiles/glyphs/sprites now go through the loopback proxy,
                    // which fetches them over the same Tor transport.
                    mapStyleURL = MapProxy.shared.start(transport: transport)
                }
                return true
            }
            lastError = "リレーが応答しません"
        } catch {
            lastCheck = Date()
            lastError = String(describing: error)
        }
        return false
    }
}
