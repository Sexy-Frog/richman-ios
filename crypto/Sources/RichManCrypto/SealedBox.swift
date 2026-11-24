import Foundation
import CryptoKit

/// AES-256-GCM sealing for the local database, byte-compatible with the Android
/// `CryptoBox` (crypto/CryptoBox.kt).
///
///   format: [1 byte version = 1][12 byte nonce/IV][ciphertext][16 byte tag]
///
/// On Android the ciphertext returned by `Cipher.doFinal` already has the GCM
/// tag appended, so the on-the-wire layout is identical. The key is a
/// non-exportable 256-bit key (Keychain / Secure Enclave on iOS — see
/// `KeychainKey`); destroying it renders all at-rest ciphertext permanently
/// unreadable (emergency wipe).
public struct SealedBox {
    public enum SealError: Error { case tooShort, unsupportedVersion }

    private static let version: UInt8 = 1
    private static let nonceLen = 12
    private static let tagLen = 16

    private let key: SymmetricKey

    public init(key: SymmetricKey) { self.key = key }

    public func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key)        // random 12-byte nonce
        var out = Data([Self.version])
        out.append(Data(box.nonce))
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    public func open(_ sealed: Data) throws -> Data {
        let bytes = [UInt8](sealed)
        guard bytes.count > 1 + Self.nonceLen + Self.tagLen else { throw SealError.tooShort }
        guard bytes[0] == Self.version else { throw SealError.unsupportedVersion }
        let nonce = try AES.GCM.Nonce(data: Data(bytes[1..<(1 + Self.nonceLen)]))
        let ctEnd = bytes.count - Self.tagLen
        let ciphertext = Data(bytes[(1 + Self.nonceLen)..<ctEnd])
        let tag = Data(bytes[ctEnd...])
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key)
    }
}
