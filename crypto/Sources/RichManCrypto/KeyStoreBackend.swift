import Foundation
import LibSignalClient

/// Persistence abstraction behind the libsignal stores — the Swift analogue of
/// the Android `Db`. All records are opaque libsignal state or small meta
/// strings; the real app backs this with a `SealedBox`-encrypted SQLite file,
/// while tests use `InMemoryKeyStore`.
///
/// Identity and registration id are created once (see `InMemoryKeyStore.createIdentity`)
/// and never change.
public protocol KeyStoreBackend: AnyObject {
    // identity (set once at first launch)
    func loadIdentityKeyPair() throws -> Data        // serialized IdentityKeyPair
    func loadLocalRegistrationId() throws -> UInt32

    // pinned peer identities, keyed by peer id
    func loadPeerIdentity(_ name: String) -> Data?
    func storePeerIdentity(_ name: String, _ serialized: Data)

    // ratchet sessions
    func loadSession(_ name: String, _ device: UInt32) -> Data?
    func storeSession(_ name: String, _ device: UInt32, _ record: Data)
    func containsSession(_ name: String, _ device: UInt32) -> Bool
    func deleteSession(_ name: String, _ device: UInt32)

    // one-time prekeys
    func loadPreKey(_ id: UInt32) -> Data?
    func storePreKey(_ id: UInt32, _ record: Data)
    func removePreKey(_ id: UInt32)
    func preKeyCount() -> Int
    func preKeyIds() -> [UInt32]

    // signed prekey (single, id = 1)
    func loadSignedPreKey(_ id: UInt32) -> Data?
    func storeSignedPreKey(_ id: UInt32, _ record: Data)

    // kyber prekey (single last-resort, id = 1)
    func loadKyberPreKey(_ id: UInt32) -> Data?
    func storeKyberPreKey(_ id: UInt32, _ record: Data)

    // small meta values (routing tag, mailbox, next prekey counter)
    func meta(_ key: String) -> String?
    func setMeta(_ key: String, _ value: String)
}

/// In-memory backend for unit tests. Not persistent; not thread-safe.
public final class InMemoryKeyStore: KeyStoreBackend {
    private var identity: Data
    private var regId: UInt32
    private var peers: [String: Data] = [:]
    private var sessions: [String: Data] = [:]
    private var preKeys: [UInt32: Data] = [:]
    private var signedPreKeys: [UInt32: Data] = [:]
    private var kyberPreKeys: [UInt32: Data] = [:]
    private var metaMap: [String: String] = [:]

    private init(identity: Data, regId: UInt32) {
        self.identity = identity
        self.regId = regId
    }

    /// Generate a fresh identity (Curve25519 identity key + 14-bit registration id).
    public static func createIdentity() -> InMemoryKeyStore {
        let pair = IdentityKeyPair.generate()
        let reg = UInt32.random(in: 1...16380) // libsignal registration ids are 14-bit
        return InMemoryKeyStore(identity: pair.serialize(), regId: reg)
    }

    private func key(_ name: String, _ device: UInt32) -> String { "\(name)|\(device)" }

    public func loadIdentityKeyPair() throws -> Data { identity }
    public func loadLocalRegistrationId() throws -> UInt32 { regId }

    public func loadPeerIdentity(_ name: String) -> Data? { peers[name] }
    public func storePeerIdentity(_ name: String, _ serialized: Data) { peers[name] = serialized }

    public func loadSession(_ name: String, _ device: UInt32) -> Data? { sessions[key(name, device)] }
    public func storeSession(_ name: String, _ device: UInt32, _ record: Data) { sessions[key(name, device)] = record }
    public func containsSession(_ name: String, _ device: UInt32) -> Bool { sessions[key(name, device)] != nil }
    public func deleteSession(_ name: String, _ device: UInt32) { sessions[key(name, device)] = nil }

    public func loadPreKey(_ id: UInt32) -> Data? { preKeys[id] }
    public func storePreKey(_ id: UInt32, _ record: Data) { preKeys[id] = record }
    public func removePreKey(_ id: UInt32) { preKeys[id] = nil }
    public func preKeyCount() -> Int { preKeys.count }
    public func preKeyIds() -> [UInt32] { Array(preKeys.keys) }

    public func loadSignedPreKey(_ id: UInt32) -> Data? { signedPreKeys[id] }
    public func storeSignedPreKey(_ id: UInt32, _ record: Data) { signedPreKeys[id] = record }

    public func loadKyberPreKey(_ id: UInt32) -> Data? { kyberPreKeys[id] }
    public func storeKyberPreKey(_ id: UInt32, _ record: Data) { kyberPreKeys[id] = record }

    public func meta(_ key: String) -> String? { metaMap[key] }
    public func setMeta(_ key: String, _ value: String) { metaMap[key] = value }
}
