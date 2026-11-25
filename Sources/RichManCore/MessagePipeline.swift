import Foundation

/// The crypto boundary the message pipeline (and the app) depend on. The real
/// implementation is `RichManCrypto.KeyManager` (libsignal, Apple-only); a mock
/// stands in for Docker/Simulator so the orchestration is unit-testable without
/// the FFI. `encrypt`/`decrypt` operate on the libsignal framing
/// `[type byte][ciphertext]` that fills the Wire payload (docs/PROTOCOL.md §3).
public protocol CryptoEngine {
    /// My own contact id: base64url(identity public, 33B).
    var myId: String { get }

    /// Encrypt a plaintext payload for `peerId` → `[libsignal type][ciphertext]`.
    func encrypt(peerId: String, plaintext: Data) throws -> Data

    /// Decrypt a `[type][ciphertext]` payload received from `peerId`.
    func decrypt(peerId: String, payload: Data) throws -> Data

    /// For a first (PreKey) message arriving on an invite mailbox, recover the
    /// sender id from the message itself. Returns nil for non-PreKey payloads.
    func peekSenderId(fromKindPayload payload: Data) -> String?
}

public enum PipelineError: Error, Equatable {
    case unknownSender
    case unsupportedKind(Int)
}

/// A received message after the envelope is opened and decrypted.
public struct OpenedMessage: Equatable {
    public let senderId: String
    public let payload: Data            // decrypted JSON (includes the sender's `rb`)
    public let type: MessageType?
    public let replyBox: String?
    public init(senderId: String, payload: Data, type: MessageType?, replyBox: String?) {
        self.senderId = senderId; self.payload = payload; self.type = type; self.replyBox = replyBox
    }
}

/// Outgoing: stamp the reply mailbox, encrypt, and seal into a 4096B envelope —
/// mirrors the Android `ChatController.transmit()`. The returned bytes are what
/// you POST to `/v1/send` for the peer's mailbox.
public enum OutgoingSealer {
    public static func seal(payload: Data, replyBox: String, to peerId: String, crypto: CryptoEngine) throws -> Data {
        let stamped = MessagePayload.stampReplyBox(payload, rb: replyBox)
        let ciphertext = try crypto.encrypt(peerId: peerId, plaintext: stamped)
        return try Wire.seal(kind: Wire.kindSignal, payload: ciphertext)
    }
}

/// Incoming: open the envelope, resolve the sender, decrypt, and read the type +
/// reply mailbox — mirrors the Android `handleIncoming`. Pass `knownSender` when
/// the fetched mailbox already maps to a contact; pass nil for an invite mailbox
/// (a first PreKey message), and the sender is recovered from the message.
public enum IncomingOpener {
    public static func open(envelope: Data, knownSender: String?, crypto: CryptoEngine) throws -> OpenedMessage {
        let env = try Wire.open(envelope)
        guard env.kind == Wire.kindSignal else { throw PipelineError.unsupportedKind(env.kind) }
        guard let sender = knownSender ?? crypto.peekSenderId(fromKindPayload: env.payload) else {
            throw PipelineError.unknownSender
        }
        let plain = try crypto.decrypt(peerId: sender, payload: env.payload)
        return OpenedMessage(
            senderId: sender,
            payload: plain,
            type: MessagePayload.type(of: plain),
            replyBox: MessagePayload.replyBox(of: plain)
        )
    }
}
