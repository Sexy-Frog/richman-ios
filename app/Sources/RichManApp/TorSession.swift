import Foundation
import Darwin
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

    /// Emergency wipe: remove Tor's data directory, cached descriptors and the
    /// debug log. This also makes the next launch bootstrap from scratch.
    static func wipeStorage() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("tor", isDirectory: true)
        PrivacyStorage.removeTree(base)
    }

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
    /// Chosen per launch so two simulators (or two app instances) never fight
    /// over 127.0.0.1:39050 on the same host.
    private var socksPort: UInt16 = 39050

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
        guard phase == .ready else { return nil }
        return transport(isolation: "default")
    }

    /// Factory used by `ChatStore`: a stable SOCKS username per mailbox makes
    /// Tor's `IsolateSOCKSAuth` put different contacts on different circuits.
    /// Captures only value types, so it is safe to hand to the relay actor.
    var readyTransportFactory: (@Sendable (String) -> RelayTransport)? {
        guard phase == .ready, configured else { return nil }
        let host = Self.relayHost
        let port = Self.relayPort
        let socks = socksPort
        return { isolation in
            SOCKS5Transport(
                proxy: SOCKS5Address(host: "127.0.0.1", port: socks),
                targetHost: host,
                targetPort: port,
                username: isolation,
                password: "x"
            )
        }
    }

    /// False when the build was produced without a relay address.
    var configured: Bool { !Self.relayHost.isEmpty }

    /// Transport for relay calls, only once the SOCKS listener is up.
    var relayTransport: SOCKS5Transport? {
        transport(isolation: "default")
    }

    func transport(isolation: String) -> SOCKS5Transport? {
        guard phase != .unsupported, configured else { return nil }
        return SOCKS5Transport(
            proxy: SOCKS5Address(host: "127.0.0.1", port: socksPort),
            targetHost: Self.relayHost,
            targetPort: Self.relayPort,
            username: isolation,
            password: "x"
        )
    }

    func start() {
        #if DEBUG
        // CI E2E uses a Tor daemon on the host Mac (simulators share its
        // loopback), which keeps the embedded-Tor lifecycle out of the E2E
        // signal path. `-rm.tor off -rm.socksPort 9050`.
        if let port = Self.externalSocksPort {
            socksPort = port
            phase = .ready
            if mapStyleURL == nil, let transport = transport(isolation: "map") {
                mapStyleURL = MapProxy.shared.start(transport: transport)
            }
            return
        }
        #endif
        #if canImport(TorSupport)
        guard launcher == nil, configured else { return }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("tor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        PrivacyStorage.excludeFromBackup(base)
        socksPort = Self.freeLoopbackPort() ?? 39050
        #if DEBUG
        let logFile: URL? = base.appendingPathComponent("tor.log")
        #else
        let logFile: URL? = nil
        #endif
        let config = TorConfig(
            socksPort: socksPort,
            dataDirectory: base,
            cacheDirectory: base.appendingPathComponent("cache", isDirectory: true),
            logFile: logFile
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

    /// DEBUG-only external SOCKS override (CI simulators).
    private static var externalSocksPort: UInt16? {
        #if DEBUG
        guard UserDefaults.standard.string(forKey: "rm.tor") == "off" else {
            return nil
        }
        let value = UserDefaults.standard.integer(forKey: "rm.socksPort")
        return value > 0 ? UInt16(value) : nil
        #else
        return nil
        #endif
    }

    /// Bind port 0 and read the assigned port, so two app instances on one
    /// host (two simulators) never collide on the SOCKS listener.
    private static func freeLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &name) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: name.sin_port)
    }

    @discardableResult
    private func check() async -> Bool {
        guard let active = relayTransport else { return false }
        let client = RelayClient(transport: active)
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
                    mapStyleURL = MapProxy.shared.start(
                        transport: self.transport(isolation: "map") ?? active
                    )
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
