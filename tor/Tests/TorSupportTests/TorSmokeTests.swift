import XCTest
import Foundation
import Darwin
@testable import TorSupport

/// Starts the real tor.xcframework daemon and verifies the SOCKS listener
/// binds. Bootstrap (which needs the live network) is not asserted; the goal is
/// to catch fatal tor_run_main configuration errors before an app build.
final class TorSmokeTests: XCTestCase {
    func testSocksListenerBinds() throws {
        let port = Self.freePort()
        XCTAssertGreaterThan(port, 0)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tor-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let launcher = TorLauncher(
            config: TorConfig(
                socksPort: port,
                dataDirectory: directory,
                cacheDirectory: directory.appendingPathComponent("cache"),
                logFile: directory.appendingPathComponent("tor.log")
            )
        )
        XCTAssertTrue(launcher.start())

        var bound = false
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if Self.canConnect(port) {
                bound = true
                break
            }
            usleep(300_000)
        }
        XCTAssertTrue(bound, "Tor SOCKS listener never bound on 127.0.0.1:\(port)")
    }

    private static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
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
        guard bound == 0 else { return 0 }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &name, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }) == 0 else { return 0 }
        return UInt16(bigEndian: name.sin_port)
    }

    private static func canConnect(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
