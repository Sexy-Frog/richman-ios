import XCTest
@testable import TorSupport

final class TorConfigTests: XCTestCase {
    func testArgumentsAreOneOptionPerEntry() {
        let config = TorConfig(
            socksPort: 39050,
            dataDirectory: URL(fileURLWithPath: "/tmp/rich man/tor"),
            cacheDirectory: URL(fileURLWithPath: "/tmp/rich man/cache"),
            logFile: URL(fileURLWithPath: "/tmp/rich man/tor.log")
        )
        let args = config.arguments()
        XCTAssertTrue(args.contains("--ignore-missing-torrc"))
        XCTAssertEqual(args.firstIndex(of: "--SocksPort").map { args[$0 + 1] }, "39050")
        XCTAssertEqual(args.firstIndex(of: "--DataDirectory").map { args[$0 + 1] },
                       "/tmp/rich man/tor")
        XCTAssertEqual(args.firstIndex(of: "--CacheDirectory").map { args[$0 + 1] },
                       "/tmp/rich man/cache")
        XCTAssertEqual(args.firstIndex(of: "--IsolateSOCKSAuth").map { args[$0 + 1] }, "1")
        XCTAssertEqual(args.firstIndex(of: "--ControlPort").map { args[$0 + 1] }, "0")
        XCTAssertEqual(args.firstIndex(of: "--ClientOnly").map { args[$0 + 1] }, "1")
        XCTAssertEqual(args.firstIndex(of: "--AvoidDiskWrites").map { args[$0 + 1] }, "1")
        XCTAssertEqual(args.firstIndex(of: "--Log").map { args[$0 + 1] },
                       "warn file /tmp/rich man/tor.log")
        // Tor rejects `--Key=Value` for these options.
        XCTAssertFalse(args.contains { $0.hasPrefix("--") && $0.contains("=") })
        XCTAssertFalse(args.contains { $0.contains(";") || $0.contains("&&") })
    }

    func testEndpointFollowsSocksPort() {
        let config = TorConfig(socksPort: 40123, dataDirectory: URL(fileURLWithPath: "/tmp/tor"))
        let launcher = TorLauncher(config: config)
        XCTAssertEqual(launcher.endpoint, TorEndpoint(host: "127.0.0.1", port: 40123))
        XCTAssertEqual(launcher.currentPhase, .stopped)
    }
}
