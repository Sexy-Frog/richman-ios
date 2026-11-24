import Foundation
import LibSignalClient
import RichManCore

/// Identity, prekey management and the thin wrapper around libsignal's
/// session building and ciphering. Mirrors the Android `KeyManager`
/// (crypto/KeyManager.kt) — same invite-bundle JSON and the same
/// `[libsignal type byte][ciphertext]` framing, so the two interoperate.
///
/// Nothing cryptographic is implemented here: X3DH/PQXDH, the double ratchet
/// and all signatures are libsignal's.
public final class KeyManager {

    public static let signedPreKeyId: UInt32 = 1
    public static let kyberPreKeyId: UInt32 = 1
    public static let deviceId: UInt32 = RichManSignalStore.deviceId
    private static let batch: UInt32 = 16
    private static let metaNextPreKey = "prekey.next"
    private static let metaTag = "me.tag"
    private static let metaBox = "me.box"

    public let backend: KeyStoreBackend
    public let store: RichManSignalStore
    private let idKeyPair: IdentityKeyPair
    private let regId: UInt32
    private let ctx = NullContext.shared

    /// Contact / group primary key: base64url(identity public, 33 bytes).
    public let id: String
    public var registrationId: UInt32 { regId }

    public init(backend: KeyStoreBackend) throws {
        self.backend = backend
        self.store = try RichManSignalStore(backend: backend)
        self.idKeyPair = try IdentityKeyPair(bytes: backend.loadIdentityKeyPair())
        self.regId = try backend.loadLocalRegistrationId()
        self.id = Base64URL.encode(idKeyPair.publicKey.serialize())
        try ensureSignedPreKey()
        try ensureKyberPreKey()
        try ensurePreKeys()
        _ = myTag()
        _ = myBox()
    }

    // MARK: local keys

    private static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    private func ensureSignedPreKey() throws {
        if backend.loadSignedPreKey(Self.signedPreKeyId) != nil { return }
        let priv = PrivateKey.generate()
        let sig = idKeyPair.privateKey.generateSignature(message: priv.publicKey.serialize())
        let rec = try SignedPreKeyRecord(id: Self.signedPreKeyId, timestamp: Self.now(), privateKey: priv, signature: sig)
        backend.storeSignedPreKey(Self.signedPreKeyId, rec.serialize())
    }

    private func ensureKyberPreKey() throws {
        if backend.loadKyberPreKey(Self.kyberPreKeyId) != nil { return }
        let pair = KEMKeyPair.generate()   // Kyber1024
        let sig = idKeyPair.privateKey.generateSignature(message: pair.publicKey.serialize())
        let rec = try KyberPreKeyRecord(id: Self.kyberPreKeyId, timestamp: Self.now(), keyPair: pair, signature: sig)
        backend.storeKyberPreKey(Self.kyberPreKeyId, rec.serialize())
    }

    public func ensurePreKeys(minimum: Int = 8) throws {
        if backend.preKeyCount() >= minimum { return }
        var next = backend.meta(Self.metaNextPreKey).flatMap { UInt32($0) } ?? 1
        for _ in 0..<Self.batch {
            let rec = try PreKeyRecord(id: next, privateKey: PrivateKey.generate())
            backend.storePreKey(next, rec.serialize())
            next &+= 1
        }
        backend.setMeta(Self.metaNextPreKey, String(next))
        prunePreKeys(next)
    }

    private func prunePreKeys(_ next: UInt32) {
        guard next > 256 else { return }
        let cutoff = next - 256
        for pid in backend.preKeyIds() where pid < cutoff { backend.removePreKey(pid) }
    }

    private func newPreKey() throws -> PreKeyRecord {
        var next = backend.meta(Self.metaNextPreKey).flatMap { UInt32($0) } ?? 1
        let rec = try PreKeyRecord(id: next, privateKey: PrivateKey.generate())
        backend.storePreKey(next, rec.serialize())
        next &+= 1
        backend.setMeta(Self.metaNextPreKey, String(next))
        return rec
    }

    public func myTag() -> Data {
        if let s = backend.meta(Self.metaTag), let d = try? Base64URL.decode(s) { return d }
        let tag = secureRandomData(16)
        backend.setMeta(Self.metaTag, Base64URL.encode(tag))
        return tag
    }

    public func myBox() -> Data {
        if let s = backend.meta(Self.metaBox), let d = try? Base64URL.decode(s) { return d }
        let box = secureRandomData(32)
        backend.setMeta(Self.metaBox, Base64URL.encode(box))
        return box
    }

    // MARK: invite bundle

    /// Build the public prekey bundle a friend obtains from our QR / invite.
    /// A fresh one-time prekey is minted per bundle. Returns the JSON bytes that
    /// go to `/v1/invite`; the exact shape matches Android's `buildBundle`.
    public func buildBundle(displayName: String) throws -> Data {
        try ensureSignedPreKey()
        try ensureKyberPreKey()
        try ensurePreKeys()
        guard let spkBytes = backend.loadSignedPreKey(Self.signedPreKeyId) else { throw CryptoError.missingKey("signed prekey") }
        guard let kpkBytes = backend.loadKyberPreKey(Self.kyberPreKeyId) else { throw CryptoError.missingKey("kyber prekey") }
        let spk = try SignedPreKeyRecord(bytes: spkBytes)
        let kpk = try KyberPreKeyRecord(bytes: kpkBytes)
        let opk = try newPreKey()

        let dict: [String: Any] = [
            "v": 1,
            "id": id,
            "n": displayName,
            "tag": Base64URL.encode(myTag()),
            "box": Base64URL.encode(myBox()),
            "reg": Int(regId),
            "spk": ["i": Int(spk.id), "p": Base64URL.encode(try spk.publicKey().serialize()), "s": Base64URL.encode(spk.signature)],
            "opk": ["i": Int(opk.id), "p": Base64URL.encode(try opk.publicKey().serialize())],
            "kpk": ["i": Int(kpk.id), "p": Base64URL.encode(try kpk.publicKey().serialize()), "s": Base64URL.encode(kpk.signature)],
        ]
        return try JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: sessions

    public func hasSession(peerId: String) -> Bool {
        backend.containsSession(peerId, Self.deviceId)
    }

    /// Pin the remote identity from the QR bundle and run X3DH + PQXDH.
    public func startSession(peerId: String, bundle bundleData: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: bundleData) as? [String: Any],
              let idStr = obj["id"] as? String,
              let regAny = obj["reg"] as? Int,
              let spk = obj["spk"] as? [String: Any],
              let kpk = obj["kpk"] as? [String: Any]
        else { throw CryptoError.badBundle("missing fields") }

        let identity = try IdentityKey(bytes: Base64URL.decode(idStr))
        guard Base64URL.encode(identity.serialize()) == peerId else { throw CryptoError.identityMismatch }

        let address = try ProtocolAddress(name: peerId, deviceId: Self.deviceId)
        _ = try store.saveIdentity(identity, for: address, context: ctx)

        let reg = UInt32(regAny)
        let signedId = try uint(spk["i"])
        let signedPub = try PublicKey(Base64URL.decode(try str(spk["p"])))
        let signedSig = try Base64URL.decode(try str(spk["s"]))
        let kyberId = try uint(kpk["i"])
        let kyberPub = try KEMPublicKey(Base64URL.decode(try str(kpk["p"])))
        let kyberSig = try Base64URL.decode(try str(kpk["s"]))

        let bundle: PreKeyBundle
        if let opk = obj["opk"] as? [String: Any],
           let opkI = opk["i"] as? Int, let opkP = opk["p"] as? String {
            bundle = try PreKeyBundle(
                registrationId: reg, deviceId: Self.deviceId,
                prekeyId: UInt32(opkI), prekey: try PublicKey(Base64URL.decode(opkP)),
                signedPrekeyId: signedId, signedPrekey: signedPub, signedPrekeySignature: signedSig,
                identity: identity,
                kyberPrekeyId: kyberId, kyberPrekey: kyberPub, kyberPrekeySignature: kyberSig)
        } else {
            bundle = try PreKeyBundle(
                registrationId: reg, deviceId: Self.deviceId,
                signedPrekeyId: signedId, signedPrekey: signedPub, signedPrekeySignature: signedSig,
                identity: identity,
                kyberPrekeyId: kyberId, kyberPrekey: kyberPub, kyberPrekeySignature: kyberSig)
        }
        try processPreKeyBundle(bundle, for: address, sessionStore: store, identityStore: store, context: ctx)
    }

    // MARK: cipher

    /// Encrypt → `[libsignal type byte][serialized message]` (goes in the Wire payload).
    public func encrypt(peerId: String, plaintext: Data) throws -> Data {
        let address = try ProtocolAddress(name: peerId, deviceId: Self.deviceId)
        let message = try signalEncrypt(message: plaintext, for: address, sessionStore: store, identityStore: store, context: ctx)
        var out = Data([message.messageType.rawValue])
        out.append(message.serialize())
        return out
    }

    public func decrypt(peerId: String, payload: Data) throws -> Data {
        let bytes = [UInt8](payload)
        guard bytes.count > 1 else { throw CryptoError.emptyCiphertext }
        let type = bytes[0]
        let body = Data(bytes[1...])
        let address = try ProtocolAddress(name: peerId, deviceId: Self.deviceId)
        if type == CiphertextMessage.MessageType.preKey.rawValue {
            let message = try PreKeySignalMessage(bytes: body)
            return try signalDecryptPreKey(
                message: message, from: address,
                sessionStore: store, identityStore: store,
                preKeyStore: store, signedPreKeyStore: store, kyberPreKeyStore: store,
                context: ctx)
        } else if type == CiphertextMessage.MessageType.whisper.rawValue {
            let message = try SignalMessage(bytes: body)
            return try signalDecrypt(message: message, from: address, sessionStore: store, identityStore: store, context: ctx)
        }
        throw CryptoError.unsupportedMessageType(type)
    }

    /// Recover the sender identity from a PreKeySignalMessage so a recipient can
    /// resolve the session before it has stored the sender's routing tag.
    public func peekPreKeyIdentity(payload: Data) -> String? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2, bytes[0] == CiphertextMessage.MessageType.preKey.rawValue else { return nil }
        return try? Base64URL.encode(PreKeySignalMessage(bytes: Data(bytes[1...])).identityKey.serialize())
    }

    // MARK: json helpers

    private func str(_ v: Any?) throws -> String {
        guard let s = v as? String else { throw CryptoError.badBundle("expected string") }
        return s
    }
    private func uint(_ v: Any?) throws -> UInt32 {
        guard let i = v as? Int else { throw CryptoError.badBundle("expected int") }
        return UInt32(i)
    }
}
