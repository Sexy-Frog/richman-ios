// swift-tools-version:5.9
import PackageDescription

// RichMan iOS — shared, platform-agnostic protocol core.
//
// This package intentionally depends only on Foundation (+ Security for CSPRNG)
// so it builds and unit-tests on a macOS CI runner with `swift build` / `swift test`,
// no Xcode project, no code signing, and no paid Apple Developer account.
//
// Later increments add:
//   - LibSignalClient (SwiftPM) for X3DH/PQXDH + Double Ratchet, in a `RichManCrypto` target
//   - the Tor transport and the SwiftUI app (an Xcode project that depends on RichManCore)
let package = Package(
    name: "RichManCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "RichManCore", targets: ["RichManCore"]),
    ],
    targets: [
        .target(
            name: "RichManCore",
            path: "Sources/RichManCore"
        ),
        .testTarget(
            name: "RichManCoreTests",
            dependencies: ["RichManCore"],
            path: "Tests/RichManCoreTests"
        ),
    ]
)
