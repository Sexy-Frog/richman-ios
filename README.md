# RichMan — iOS

Native iOS client for RichMan. Mirrors the Android app's protocol exactly:
libsignal (X3DH + PQXDH/Kyber1024, Double Ratchet), fixed 4096‑byte padded
envelopes, and a `/v1` onion relay API.

## Why a SwiftPM core first

iOS apps must be compiled, run and signed on **macOS + Xcode**; this repo is
developed on Windows and built on **cloud CI (GitHub Actions macOS runners)**.

To make progress verifiable *without* a Mac in the loop, the platform‑agnostic
protocol logic lives in a dependency‑light SwiftPM library, **`RichManCore`**,
that builds and unit‑tests with plain `swift build` / `swift test`. No Xcode
project, no code signing, and no paid Apple Developer account are needed for this
layer — CI runs it on every push.

```
ios/
  Package.swift              RichManCore library + tests
  Sources/RichManCore/
    Wire.swift               4096B fixed envelope (== android net/Wire.kt)
    Base64URL.swift          url-safe, no padding (== android util/B64.kt)
    Random.swift             CSPRNG helper
    Identifiers.swift        box(32) / tag(16) / id / gid
    RelayTransport.swift     transport protocol (Tor plugs in later)
    RelayClient.swift        /v1 API (== android net/RelayClient.kt)
    Messages.swift           Codable payload models (docs/PROTOCOL.md §6)
  Tests/RichManCoreTests/    XCTest (mirrors android WireTest.kt + relay/base64)
  .github/workflows/ci.yml   macOS CI: swift build + swift test
```

## Build / test locally (needs a Swift toolchain)

```
cd ios
swift build
swift test
```

Swift is available on macOS, Linux and Windows. On Windows the Security‑framework
CSPRNG is unavailable, so `Random.swift` falls back to `SystemRandomNumberGenerator`
there; on Apple platforms it uses `SecRandomCopyBytes`.

## Roadmap (increments)

1. **Protocol core** — Wire, relay client, identifiers, message models ✅ (this commit)
2. **Crypto** — add `LibSignalClient` (SwiftPM); `RichManCrypto` target wrapping
   identity/prekeys/sessions, sealed local store via Keychain + Data Protection.
3. **Tor transport** — embed Tor (Tor.framework / Arti), implement `RelayTransport`
   over the SOCKS proxy; no clearnet fallback.
4. **App** — Xcode project (SwiftUI): talks list, chat, friends, group info,
   settings, Signal‑blue theme — while the protocol underneath is the native
   libsignal/Tor stack. Then PIN lock + emergency wipe, maps (MapLibre iOS),
   file transfer, voice calls (ADPCM).
5. **Distribution** — CI `xcodebuild` + TestFlight (requires Apple Developer account).

## Notes

- This library is byte/shape‑compatible with the Android client so the two
  interoperate through the same onion relay. Keep it in lockstep with the
  protocol spec and the Android sources.
- The workflow sits at the repo root; no server or secret material is involved.
