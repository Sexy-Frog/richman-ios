import Foundation
import RichManCore

/// The single boundary the UI uses for identity, sessions and ciphering. The
/// real implementation is `RichManCrypto` (libsignal — builds on macOS/iOS
/// device only); the mock below lets the whole app compile and run in the iOS
/// Simulator with no FFI and no Apple Developer account, so UI work is CI-
/// verifiable today.
protocol CryptoProvider {
    /// My contact id: base64url(identity public, 33B).
    var myId: String { get }
    /// Build the invite prekey-bundle JSON (shape = `PrekeyBundle`).
    func buildInviteBundle(displayName: String) throws -> Data
    /// Run X3DH + PQXDH from a scanned bundle.
    func startSession(peerId: String, bundle: Data) throws
    /// Encrypt → `[libsignal type][ciphertext]` for the Wire payload.
    func encrypt(peerId: String, plaintext: Data) throws -> Data
    /// Decrypt a received `[type][ciphertext]` payload.
    func decrypt(peerId: String, payload: Data) throws -> Data
}

/// No-crypto stand-in for Simulator / UI development. Produces well-shaped but
/// non-secure values so screens render and flows wire up; never ships in a
/// device build.
final class MockCryptoProvider: CryptoProvider {
    let myId = "mock-" + String(UUID().uuidString.lowercased().prefix(8))

    func buildInviteBundle(displayName: String) throws -> Data {
        let qr = QRInvite(id: myId, n: displayName, tag: "mockTag", box: "mockBox", k: "mockKey", t: "mockToken")
        return try qr.toPayloadJSON()
    }
    func startSession(peerId: String, bundle: Data) throws {}
    func encrypt(peerId: String, plaintext: Data) throws -> Data { plaintext }
    func decrypt(peerId: String, payload: Data) throws -> Data { payload }
}
