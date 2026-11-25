import Foundation

/// Where the embedded Tor SOCKS listener lives once Tor is up.
public struct TorEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public init(host: String = "127.0.0.1", port: UInt16) {
        self.host = host
        self.port = port
    }
}

/// Tor startup configuration. Torrc-equivalent options only, no shell strings:
/// each option becomes its own argv entry so a path with spaces can never be
/// re-parsed.
public struct TorConfig: Sendable {
    public var socksPort: UInt16
    public var dataDirectory: URL
    public var cacheDirectory: URL?
    public var logFile: URL?
    /// Directory mirroring is unnecessary for a client-only onion app.
    public var clientOnly: Bool
    public var avoidDiskWrites: Bool

    public init(
        socksPort: UInt16 = 39050,
        dataDirectory: URL,
        cacheDirectory: URL? = nil,
        logFile: URL? = nil,
        clientOnly: Bool = true,
        avoidDiskWrites: Bool = true
    ) {
        self.socksPort = socksPort
        self.dataDirectory = dataDirectory
        self.cacheDirectory = cacheDirectory
        self.logFile = logFile
        self.clientOnly = clientOnly
        self.avoidDiskWrites = avoidDiskWrites
    }

    /// The arguments passed to `tor_run_main` (without argv[0]).
    public func arguments() -> [String] {
        var args: [String] = [
            "--ignore-missing-torrc",
            "--SocksPort=\(socksPort)",
            "--DataDirectory=\(dataDirectory.path)",
            "--ControlPort=0",
            // Every SOCKS username gets its own circuit, which the app uses to
            // keep each friend's mailbox on a separate connection path.
            "--IsolateSOCKSAuth=1",
        ]
        if clientOnly { args.append("--ClientOnly=1") }
        if avoidDiskWrites { args.append("--AvoidDiskWrites=1") }
        if let cacheDirectory {
            args.append("--CacheDirectory=\(cacheDirectory.path)")
        }
        if let logFile {
            args.append("--Log=warn file \(logFile.path)")
        }
        return args
    }
}

public enum TorPhase: Sendable, Equatable {
    case stopped
    case starting
    case exited(Int32)
}
