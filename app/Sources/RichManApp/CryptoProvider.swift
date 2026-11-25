import Foundation
import RichManCore

/// The single boundary the UI uses for identity, sessions and ciphering. It
/// refines `RichManCore.CryptoEngine` (myId/encrypt/decrypt/peekSenderId — the
/// same boundary the message pipeline uses) and adds the friend-add operations.
/// The real implementation is `RichManCrypto` (libsignal — builds on macOS/iOS
/// device only); the mock below lets the whole app compile and run in the iOS
/// Simulator with no FFI and no Apple Developer account, so UI work is CI-
/// verifiable today.
protocol CryptoProvider: CryptoEngine {
    /// Build the invite prekey-bundle JSON (shape = `PrekeyBundle`) for a
    /// freshly minted per-contact mailbox.
    func buildInviteBundle(displayName: String, box: Data) throws -> Data
    /// Run X3DH + PQXDH from a scanned bundle.
    func startSession(peerId: String, bundle: Data) throws
    /// Decrypt the opaque invite blob fetched from the relay (AES-256-GCM under
    /// the QR-only key). The mock returns it unchanged.
    func openSealedInvite(_ sealed: Data, key: Data) throws -> Data
    /// Seal a prekey bundle for `/v1/invite` (AES-256-GCM, nonce-prefixed).
    func sealInvite(_ plain: Data, key: Data) throws -> Data
    /// Emergency wipe of the key material / sealed store. The mock has none.
    func wipeLocalState()
}

enum CryptoProviderFactory {
    /// Why the real provider fell back to the mock (DEBUG/E2E diagnostics).
    static var lastError: String?

    static func make() -> CryptoProvider {
        #if REAL_CRYPTO
        do {
            return try LibSignalCryptoProvider()
        } catch {
            lastError = String(describing: error)
            NSLog("RichManCrypto init failed: \(error)")
        }
        #endif
        return MockCryptoProvider()
    }
}

/// No-crypto stand-in for Simulator / UI development. Produces well-shaped but
/// non-secure values so screens render and flows wire up; never ships in a
/// device build.
final class MockCryptoProvider: CryptoProvider {
    let myId = "mock-" + String(UUID().uuidString.lowercased().prefix(8))

    func buildInviteBundle(displayName: String, box: Data) throws -> Data {
        let qr = QRInvite(
            id: myId, n: displayName, tag: "mockTag",
            box: Base64URL.encode(box), k: "mockKey", t: "mockToken"
        )
        return try qr.toPayloadJSON()
    }
    func startSession(peerId: String, bundle: Data) throws {}
    func openSealedInvite(_ sealed: Data, key: Data) throws -> Data { sealed }
    func sealInvite(_ plain: Data, key: Data) throws -> Data { plain }
    func wipeLocalState() {}
    func encrypt(peerId: String, plaintext: Data) throws -> Data { plaintext }
    func decrypt(peerId: String, payload: Data) throws -> Data { payload }
    func peekSenderId(fromKindPayload payload: Data) -> String? { nil }
}
