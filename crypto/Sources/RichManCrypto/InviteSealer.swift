import Foundation
import CryptoKit

/// Seals the prekey bundle for a one-time QR invite, byte-compatible with
/// Android `ChatController.createInvite()`:
///
///   sealed = nonce(12) ‖ AES-256-GCM(ciphertext ‖ tag)
///
/// The 32-byte key travels only inside the QR (out of band); the relay stores
/// the opaque blob and never sees the identity key, name or prekeys.
public enum InviteSealer {
    public enum SealError: Error, Equatable {
        case badKey
        case tooShort
        case openFailed
    }

    public static func seal(_ plain: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw SealError.badKey }
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key))
        guard let combined = box.combined else { throw SealError.openFailed }
        return combined
    }

    public static func open(_ sealed: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw SealError.badKey }
        guard sealed.count > 12 + 16 else { throw SealError.tooShort }
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else {
            throw SealError.openFailed
        }
        do {
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw SealError.openFailed
        }
    }

    /// Fresh key for one invite (goes in the QR, never to the relay).
    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}
