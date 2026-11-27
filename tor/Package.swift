// swift-tools-version:5.9
import PackageDescription

// Embedded Tor for iOS/macOS, using the official Tor C API from
// iCepa's prebuilt tor.xcframework. Kept as its own small package so the
// mock/Simulator app build and the fast CI jobs never download the 150 MB
// framework; only the "iOS Tor" workflow builds this.
//
// The framework is tor 0.4.9.x (release tag 409.17.1) and is the same Tor the
// Android app's kmp-tor runtime ships. We drive it through `tor_run_main`, not
// the Objective-C TORThread wrapper, so only the public C API is required.
let package = Package(
    name: "TorSupport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "TorSupport", targets: ["TorSupport"]),
    ],
    targets: [
        // Vendor/tor.xcframework is produced by `scripts/fetch-tor.sh` (run in
        // CI before building). It contains a dynamic Tor.framework that exports
        // only the public tor_* C API (Tor's bundled OpenSSL stays private).
        .binaryTarget(
            name: "tor",
            path: "Vendor/tor.xcframework"
        ),
        // Header-only shim: the public Tor C API is vendored in this target, so
        // TorSupport does not depend on the binary framework's headers.
        .target(
            name: "CTorMin",
            dependencies: ["tor"],
            path: "Sources/CTorMin",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "TorSupport",
            dependencies: ["CTorMin"],
            path: "Sources/TorSupport"
        ),
        .testTarget(
            name: "TorSupportTests",
            dependencies: ["TorSupport"],
            path: "Tests/TorSupportTests"
        ),
    ]
)
