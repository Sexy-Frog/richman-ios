#if REAL_CRYPTO
import Foundation
import CryptoKit
import RichManCrypto
import RichManCore

/// Real crypto provider: libsignal (X3DH + PQXDH, double ratchet) on top of a
/// SealedBox-encrypted local store whose AES key lives in the Keychain.
final class LibSignalCryptoProvider: CryptoProvider {
    private let keys: KeyManager

    init() throws {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let key = try KeychainKey.loadOrCreate()
        let backend = try SealedFileKeyStore(
            url: base.appendingPathComponent("signal.store"),
            key: key
        )
        keys = try KeyManager(backend: backend)
    }

    var myId: String { keys.id }

    func buildInviteBundle(displayName: String) throws -> Data {
        try keys.buildBundle(displayName: displayName)
    }

    func startSession(peerId: String, bundle: Data) throws {
        try keys.startSession(peerId: peerId, bundle: bundle)
    }

    func openSealedInvite(_ sealed: Data, key: Data) throws -> Data {
        try InviteSealer.open(sealed, key: key)
    }

    func sealInvite(_ plain: Data, key: Data) throws -> Data {
        try InviteSealer.seal(plain, key: key)
    }

    func encrypt(peerId: String, plaintext: Data) throws -> Data {
        try keys.encrypt(peerId: peerId, plaintext: plaintext)
    }

    func decrypt(peerId: String, payload: Data) throws -> Data {
        try keys.decrypt(peerId: peerId, payload: payload)
    }

    func peekSenderId(fromKindPayload payload: Data) -> String? {
        keys.peekPreKeyIdentity(payload: payload)
    }
}
#endif
