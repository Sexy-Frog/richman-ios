import Foundation
import LibSignalClient

/// libsignal storage backed by a `KeyStoreBackend`. Mirrors the Android
/// `SignalStore` (crypto/SignalStore.kt). Nothing cryptographic lives here —
/// all records are opaque libsignal state.
public final class RichManSignalStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore, KyberPreKeyStore, SessionStore {

    public static let deviceId: UInt32 = 1

    public let backend: KeyStoreBackend
    private let idKeyPair: IdentityKeyPair
    private let regId: UInt32

    public init(backend: KeyStoreBackend) throws {
        self.backend = backend
        self.idKeyPair = try IdentityKeyPair(bytes: backend.loadIdentityKeyPair())
        self.regId = try backend.loadLocalRegistrationId()
    }

    // MARK: IdentityKeyStore

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair { idKeyPair }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 { regId }

    public func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        let serialized = identity.serialize()
        let previous = backend.loadPeerIdentity(address.name)
        backend.storePeerIdentity(address.name, serialized)
        if let previous, previous != serialized { return .replacedExisting }
        return .newOrUnchanged
    }

    public func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        guard let known = backend.loadPeerIdentity(address.name) else { return true }
        return known == identity.serialize()
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        guard let bytes = backend.loadPeerIdentity(address.name) else { return nil }
        return try IdentityKey(bytes: bytes)
    }

    // MARK: PreKeyStore

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let bytes = backend.loadPreKey(id) else { throw CryptoError.missingKey("prekey \(id)") }
        return try PreKeyRecord(bytes: bytes)
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        backend.storePreKey(id, record.serialize())
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws {
        backend.removePreKey(id)
    }

    // MARK: SignedPreKeyStore

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let bytes = backend.loadSignedPreKey(id) else { throw CryptoError.missingKey("signed prekey \(id)") }
        return try SignedPreKeyRecord(bytes: bytes)
    }

    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        backend.storeSignedPreKey(id, record.serialize())
    }

    // MARK: KyberPreKeyStore

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let bytes = backend.loadKyberPreKey(id) else { throw CryptoError.missingKey("kyber prekey \(id)") }
        return try KyberPreKeyRecord(bytes: bytes)
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        backend.storeKyberPreKey(id, record.serialize())
    }

    /// The single kyber prekey is a long-lived last-resort key (like Signal's own
    /// fallback); it is never consumed. Reuse is safe for PQXDH because each
    /// session still mixes in a fresh base key.
    public func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        // no-op
    }

    // MARK: SessionStore

    public func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        guard let bytes = backend.loadSession(address.name, address.deviceId) else { return nil }
        return try SessionRecord(bytes: bytes)
    }

    public func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let bytes = backend.loadSession(address.name, address.deviceId) else {
                throw CryptoError.missingKey("session \(address.name)")
            }
            return try SessionRecord(bytes: bytes)
        }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        backend.storeSession(address.name, address.deviceId, record.serialize())
    }
}
