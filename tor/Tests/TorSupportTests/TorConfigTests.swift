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
        XCTAssertTrue(args.contains("--SocksPort=39050"))
        XCTAssertTrue(args.contains("--DataDirectory=/tmp/rich man/tor"))
        XCTAssertTrue(args.contains("--CacheDirectory=/tmp/rich man/cache"))
        XCTAssertTrue(args.contains("--IsolateSOCKSAuth=1"))
        XCTAssertTrue(args.contains("--ControlPort=0"))
        XCTAssertTrue(args.contains("--ClientOnly=1"))
        XCTAssertTrue(args.contains("--AvoidDiskWrites=1"))
        XCTAssertTrue(args.contains("--Log=warn file /tmp/rich man/tor.log"))
        // No option is a compound shell string.
        XCTAssertFalse(args.contains { $0.contains(";") || $0.contains("&&") })
    }

    func testEndpointFollowsSocksPort() {
        let config = TorConfig(socksPort: 40123, dataDirectory: URL(fileURLWithPath: "/tmp/tor"))
        let launcher = TorLauncher(config: config)
        XCTAssertEqual(launcher.endpoint, TorEndpoint(host: "127.0.0.1", port: 40123))
        XCTAssertEqual(launcher.currentPhase, .stopped)
    }
}
