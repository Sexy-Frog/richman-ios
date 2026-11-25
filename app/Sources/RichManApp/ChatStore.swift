import Foundation
import SwiftUI
import RichManCore

/// Shared app state across the hub tabs (contacts, conversations, messages) and
/// the single place the UI reaches the crypto boundary. Today it holds state in
/// memory and echoes sends locally; the real relay send/receive loop
/// (OutgoingSealer/IncomingOpener over a RelayTransport) plugs in here next,
/// without changing the screens.
@MainActor
final class ChatStore: ObservableObject {
    @Published var displayName: String
    @Published var contacts: [Contact] = []
    @Published private(set) var messagesByPeer: [String: [ChatMessage]] = [:]
    /// Blocked contact ids (App Store UGC requirement — blocked peers can't be
    /// messaged and their inbound messages are dropped). Persisted in UserDefaults.
    @Published private(set) var blockedIds: Set<String> = []
    private let blockedKey = "rm.blocked"

    let crypto: CryptoProvider
    /// Real relay pipeline (seal/send, fetch/open). Transport is a Simulator stub
    /// for now; the Tor transport + box plumbing activate it on device.
    let relay: RelayService

    init(displayName: String,
         crypto: CryptoProvider = MockCryptoProvider(),
         transport: RelayTransport = StubRelayTransport()) {
        self.displayName = displayName
        self.crypto = crypto
        self.relay = RelayService(transport: transport, crypto: crypto)
        if let saved = UserDefaults.standard.stringArray(forKey: blockedKey) {
            self.blockedIds = Set(saved)
        }
    }

    var myId: String { crypto.myId }

    // MARK: blocking (App Store UGC safety)

    func isBlocked(_ peerId: String) -> Bool { blockedIds.contains(peerId) }

    func setBlocked(_ peerId: String, _ blocked: Bool) {
        if blocked { blockedIds.insert(peerId) } else { blockedIds.remove(peerId) }
        UserDefaults.standard.set(Array(blockedIds), forKey: blockedKey)
    }

    func messages(for peerId: String) -> [ChatMessage] { messagesByPeer[peerId] ?? [] }

    func contact(_ peerId: String) -> Contact? { contacts.first { $0.id == peerId } }

    /// Append an outgoing message. TODO: stamp rb → crypto.encrypt →
    /// OutgoingSealer.seal → RelayClient.send(to: peer.box).
    func send(to peerId: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isBlocked(peerId) else { return }
        messagesByPeer[peerId, default: []].append(
            ChatMessage(id: UUID().uuidString, body: body, mine: true, ts: Date())
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = body
        }
        objectWillChange.send()
    }

    /// Record an inbound message (will be called by the relay receive loop).
    func receive(from peerId: String, text: String) {
        guard !isBlocked(peerId) else { return }   // drop messages from blocked peers
        messagesByPeer[peerId, default: []].append(
            ChatMessage(id: UUID().uuidString, body: text, mine: false, ts: Date())
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = text
            contacts[i].unread += 1
        }
    }

    func markRead(_ peerId: String) {
        if let i = contacts.firstIndex(where: { $0.id == peerId }) { contacts[i].unread = 0 }
    }

    /// My one-time invite to show as a QR. For the mock this is a QRInvite JSON;
    /// the live provider will mint a relay-backed invite (createInvite).
    func makeInvite() throws -> String {
        String(decoding: try crypto.buildInviteBundle(displayName: displayName), as: UTF8.self)
    }

    /// Add a contact from a scanned invite. TODO: fetch the sealed bundle by
    /// token, validate against the QR, and crypto.startSession.
    @discardableResult
    func addFriend(inviteText: String) throws -> Contact {
        let qr = try QRInvite.parse(inviteText)
        try qr.checkNotSelf(localId: crypto.myId)
        if let existing = contact(qr.id) { return existing }
        let c = Contact(id: qr.id, name: qr.n.isEmpty ? "名前未設定" : qr.n)
        contacts.append(c)
        return c
    }
}

// MARK: shared models (single source of truth for the screens)

struct Contact: Identifiable, Hashable {
    let id: String          // base64url identity
    var name: String
    var lastMessage: String = ""
    var unread: Int = 0
}

struct ChatMessage: Identifiable, Hashable {
    let id: String
    var body: String
    var mine: Bool
    var ts: Date
}
