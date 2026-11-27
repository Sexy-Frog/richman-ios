import Foundation
import Darwin
import RichManCore
#if canImport(TorSupport)
import TorSupport
#endif

/// Owns the network path to the relay. The default is a direct HTTPS transport
/// (no bootstrap delay, reliable push registration); an optional high-anonymity
/// mode routes everything through the embedded Tor daemon. In the mock /
/// Simulator build without TorSupport, direct mode still works.
@MainActor
final class TorSession: ObservableObject {
    /// The relay's v3 onion address, injected at build time (`RM_RELAY_HOST`)
    /// instead of living in this public repository (docs/DESIGN.md §9).
    static var relayHost: String {
        (Bundle.main.object(forInfoDictionaryKey: "RMRelayHost") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static let relayPort: UInt16 = 80

    /// Public HTTPS relay endpoint (Apache `/relay/` proxy). Not a secret.
    static var directRelayURL: URL? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "RMDirectRelayURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = "https://kelvins.works/relay/"
        return URL(string: raw.isEmpty ? fallback : raw)
    }

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
    private var cachedDirect: DirectTransport?
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
        if !useTor {
            return reachable ? "直接接続（HTTPS）" : "直接接続（未確認）"
        }
        if Self.relayHost.isEmpty { return "リレー未設定" }
        return switch phase {
        case .unsupported: "このビルドでは無効"
        case .stopped: "停止"
        case .starting: "起動中…"
        case .ready: reachable ? "接続済み" : "起動済み（未接続）"
        case .failed(let message): "失敗: \(message)"
        }
    }

    /// Default: direct HTTPS. `rm.useTor` opts into the high-anonymity Tor path
    /// (takes effect on the next launch).
    var useTor: Bool {
        UserDefaults.standard.object(forKey: "rm.useTor") as? Bool ?? false
    }

    private var directTransport: DirectTransport? {
        guard !useTor, let url = Self.directRelayURL else { return nil }
        if let cachedDirect { return cachedDirect }
        let transport = DirectTransport(baseURL: url)
        cachedDirect = transport
        return transport
    }

    /// Transport for relay calls. Direct mode is ready immediately; Tor mode
    /// waits for the SOCKS path to reach the relay.
    var readyTransport: RelayTransport? {
        if !useTor { return directTransport }
        guard phase == .ready else { return nil }
        return transport(isolation: "default")
    }

    /// Factory used by `ChatStore`. In Tor mode a stable SOCKS username per
    /// mailbox isolates contacts; direct mode shares the HTTPS session.
    var readyTransportFactory: (@Sendable (String) -> RelayTransport)? {
        if !useTor {
            guard let transport = directTransport else { return nil }
            return { _ in transport }
        }
        guard phase == .ready, !Self.relayHost.isEmpty else { return nil }
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

    /// False when the build has neither a direct URL nor an onion address.
    var configured: Bool { Self.directRelayURL != nil || !Self.relayHost.isEmpty }

    /// Transport for relay calls (direct or Tor).
    var relayTransport: RelayTransport? {
        if !useTor { return directTransport }
        return transport(isolation: "default")
    }

    func transport(isolation: String) -> SOCKS5Transport? {
        guard phase != .unsupported, !Self.relayHost.isEmpty else { return nil }
        return SOCKS5Transport(
            proxy: SOCKS5Address(host: "127.0.0.1", port: socksPort),
            targetHost: Self.relayHost,
            targetPort: Self.relayPort,
            username: isolation,
            password: "x"
        )
    }

    func start() {
        if !useTor {
            phase = .ready
            if mapStyleURL == nil, let transport = readyTransport {
                mapStyleURL = MapProxy.shared.start(transport: transport)
            }
            checkNow()
            return
        }
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
                    // Tiles/glyphs/sprites go through the loopback proxy.
                    let mapTransport = useTor
                        ? (self.transport(isolation: "map") ?? active)
                        : active
                    mapStyleURL = MapProxy.shared.start(transport: mapTransport)
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
