// swift-tools-version:5.9
import PackageDescription

// RichManCrypto — the libsignal-backed crypto layer (identity, prekeys,
// sessions, message framing) + local sealing (AES-GCM).
//
// SEPARATE package on purpose: it depends on LibSignalClient, whose native Rust
// FFI is Apple-only and must be BUILT FROM SOURCE (see INTEGRATION.md). Keeping
// it apart lets the ../ RichManCore package keep building & testing on plain
// Linux/Docker. This package only builds on macOS CI once the libsignal FFI is
// present. The LibSignalClient dependency below is a path to a vendored
// submodule (third_party/libsignal) pinned to v0.86.5 — matching the Android
// app's org.signal:libsignal-android:0.86.5.
let package = Package(
    name: "RichManCrypto",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "RichManCrypto", targets: ["RichManCrypto"]),
    ],
    dependencies: [
        .package(path: ".."),                              // RichManCore
        .package(path: "third_party/libsignal/swift"),     // LibSignalClient (v0.86.5, FFI built from source)
    ],
    targets: [
        .target(
            name: "RichManCrypto",
            dependencies: [
                .product(name: "RichManCore", package: "RichManCore"),
                .product(name: "LibSignalClient", package: "LibSignalClient"),
            ],
            path: "Sources/RichManCrypto"
        ),
        .testTarget(
            name: "RichManCryptoTests",
            dependencies: ["RichManCrypto"],
            path: "Tests/RichManCryptoTests"
        ),
    ]
)
