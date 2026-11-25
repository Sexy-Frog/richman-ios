import Foundation
import CTorMin
#if canImport(Darwin)
import Darwin
#endif

/// Runs the embedded Tor daemon on a dedicated thread and exposes its SOCKS
/// listener. `tor_run_main` blocks until Tor exits and cannot be stopped from
/// the public API, so there is intentionally no `stop()`: the daemon lives for
/// the process lifetime, exactly like kmp-tor's daemon on Android.
public final class TorLauncher: @unchecked Sendable {
    public let config: TorConfig
    public var endpoint: TorEndpoint { TorEndpoint(port: config.socksPort) }

    private let lock = NSLock()
    private var started = false
    private var thread: Thread?
    private var phase: TorPhase = .stopped

    public init(config: TorConfig) {
        self.config = config
    }

    public var currentPhase: TorPhase {
        lock.lock()
        defer { lock.unlock() }
        return phase
    }

    /// Idempotent: only one Tor instance can run per process.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        if started {
            lock.unlock()
            return false
        }
        started = true
        phase = .starting
        let config = self.config
        let thread = Thread { [weak self] in
            let code = Self.runDaemon(config: config)
            self?.markExited(code)
        }
        thread.name = "RichManTor"
        thread.stackSize = 4 * 1024 * 1024
        self.thread = thread
        lock.unlock()
        thread.start()
        return true
    }

    private func markExited(_ code: Int32) {
        lock.lock()
        phase = .exited(code)
        started = false
        lock.unlock()
    }

    /// Never returns until Tor exits. Tor keeps the argv pointer, so the whole
    /// call (configuration + argv storage + main) happens inside one pinned
    /// buffer scope.
    private static func runDaemon(config: TorConfig) -> Int32 {
        let arguments = ["tor"] + config.arguments()
        var cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer {
            for pointer in cArguments { free(pointer) }
        }

        guard let configuration = tor_main_configuration_new() else { return -1 }
        defer { tor_main_configuration_free(configuration) }

        return cArguments.withUnsafeMutableBufferPointer { buffer -> Int32 in
            let set = tor_main_configuration_set_command_line(
                configuration,
                Int32(buffer.count),
                buffer.baseAddress
            )
            guard set == 0 else { return -1 }
            return tor_run_main(configuration)
        }
    }
}
