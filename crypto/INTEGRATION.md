# RichManCrypto — libsignal integration & verification

This package wraps **libsignal** to match the Android app exactly (same
invite-bundle JSON, same `[type byte][ciphertext]` framing, PQXDH/Kyber1024).

## Status (honest)

The Swift sources here were written against the **exact libsignal 0.86.5 Swift
API** (verified file-by-file from `signalapp/libsignal` at tag `v0.86.5`), but
they have **NOT been compiled yet**. This layer cannot be built on this Windows
dev machine or under the Docker/Linux flow used for `RichManCore`, because:

- `LibSignalClient`'s SwiftPM manifest lives at `swift/Package.swift` and links a
  native Rust FFI via `.systemLibrary(SignalFfi)` — it is **not** a drop-in binary
  SPM dependency.
- There is **no official SwiftPM/binary distribution**. The community xcframework
  repos are third-party binaries and lag at 0.79.x — unacceptable supply-chain
  risk for this app, and a version mismatch with Android (0.86.5).

So the one correct path is to **build the FFI from source at v0.86.5**, which only
runs/validates on **macOS CI**. Compiling + testing this package is the immediate
next step and is a prerequisite for trusting any of this code.

## How to wire it (macOS CI)

1. Vendor libsignal pinned to the Android version:
   ```
   git submodule add https://github.com/signalapp/libsignal third_party/libsignal
   git -C third_party/libsignal checkout v0.86.5
   ```
2. Build the Rust FFI (needs the Rust toolchain; produces `libsignal_ffi.a` and
   the `SignalFfi` module consumed by the Swift target):
   ```
   third_party/libsignal/swift/build_ffi.sh --release
   ```
3. `swift build` / `swift test` this package (macOS runner). The `Package.swift`
   here already points `LibSignalClient` at `third_party/libsignal/swift`.

### CI job sketch (add to .github/workflows)

```yaml
  crypto:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - uses: dtolnay/rust-toolchain@stable
      - run: ./third_party/libsignal/swift/build_ffi.sh --release
        working-directory: ios/crypto
      - run: swift test
        working-directory: ios/crypto
```

## What to verify first on CI

A full offline handshake + round-trip with two `InMemoryKeyStore` identities:
`buildBundle` (A) → `startSession` (B) → `encrypt`/`decrypt` both directions,
asserting the first B→A message is a **preKey** type and later ones are
**whisper**. Plus a `SealedBox` seal/open round-trip and a wrong-key failure.
(Those tests live in `Tests/RichManCryptoTests/` — to be added with the CI wiring.)

## Interop invariant

The bytes that cross the wire are: the **invite-bundle JSON** (shape in
`KeyManager.buildBundle`) and the **envelope payload** `[libsignal type][message]`.
Both are identical to Android's `KeyManager`, so iOS↔Android sessions work as
long as both sides stay on libsignal 0.86.x and this framing is unchanged.
