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
        .binaryTarget(
            name: "tor",
            url: "https://github.com/iCepa/Tor.framework/releases/download/409.17.1/tor.xcframework.zip",
            checksum: "14e7875f5452cdbfd0fbc4efbaa1b4d16855a7fa94d42580adf4d73adeb241d1"
        ),
        // Header-only shim: the xcframework has no module map, so we expose
        // `feature/api/tor_api.h` under a SwiftPM module name.
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
