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
    @Published var groups: [ChatGroup] = []
    @Published private(set) var messagesByPeer: [String: [ChatMessage]] = [:]
    @Published private(set) var groupMessages: [String: [ChatMessage]] = [:]
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
        DemoData.seed(into: self)
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
    func send(to peerId: String, text: String,
              kind: ChatMessage.Kind = .text,
              replyTo: String? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isBlocked(peerId) else { return }
        messagesByPeer[peerId, default: []].append(
            ChatMessage(id: UUID().uuidString, body: body, mine: true, ts: Date(),
                        kind: kind, replyTo: replyTo)
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = kind == .text ? body : (kind == .image ? "画像" : "ファイル")
        }
        objectWillChange.send()
    }

    /// Simulated transport acknowledgements (the relay loop will drive these).
    func markDelivered(_ peerId: String) {
        guard var list = messagesByPeer[peerId] else { return }
        for i in list.indices where list[i].mine && list[i].delivery == .sent {
            list[i].delivery = .delivered
        }
        messagesByPeer[peerId] = list
    }

    func markMyMessagesRead(_ peerId: String) {
        guard var list = messagesByPeer[peerId] else { return }
        for i in list.indices where list[i].mine {
            list[i].delivery = .read
        }
        messagesByPeer[peerId] = list
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

    // MARK: data deletion (this device only)

    /// Delete every message on this device, keeping contacts.
    func clearAllMessages() {
        messagesByPeer.removeAll()
        for i in contacts.indices {
            contacts[i].lastMessage = ""
            contacts[i].unread = 0
        }
    }

    /// Delete contacts and messages on this device. The peer's copy is untouched.
    func clearAllContacts() {
        contacts.removeAll()
        messagesByPeer.removeAll()
    }

    func removeContact(_ peerId: String) {
        contacts.removeAll { $0.id == peerId }
        messagesByPeer.removeValue(forKey: peerId)
    }

    // MARK: groups (hub fan-out lands with the relay loop)

    func group(_ id: String) -> ChatGroup? { groups.first { $0.id == id } }

    func messages(forGroup id: String) -> [ChatMessage] { groupMessages[id] ?? [] }

    func memberNames(of group: ChatGroup) -> [String] {
        group.memberIds.map { id in contacts.first { $0.id == id }?.name ?? "メンバー" }
    }

    @discardableResult
    func createGroup(name: String, memberIds: [String]) -> ChatGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = ChatGroup(
            id: "group-\(UUID().uuidString.prefix(8))",
            name: trimmed.isEmpty ? "グループ" : trimmed,
            memberIds: memberIds
        )
        groups.append(group)
        groupMessages[group.id] = []
        return group
    }

    func send(toGroup id: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        groupMessages[id, default: []].append(
            ChatMessage(id: UUID().uuidString, body: body, mine: true, ts: Date())
        )
    }

    func receive(inGroup id: String, from sender: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        groupMessages[id, default: []].append(
            ChatMessage(
                id: UUID().uuidString, body: body, mine: false, ts: Date(), senderName: sender
            )
        )
    }

    func deleteGroup(_ id: String) {
        groups.removeAll { $0.id == id }
        groupMessages.removeValue(forKey: id)
    }

    func seedGroups(_ groups: [ChatGroup], messages: [String: [ChatMessage]]) {
        self.groups = groups
        self.groupMessages = messages
    }

    /// Seed deterministic content for screenshots/demo builds (DEBUG only).
    func seed(contacts: [Contact], messages: [String: [ChatMessage]]) {
        var list = contacts
        self.messagesByPeer = messages
        for i in list.indices {
            if let last = messages[list[i].id]?.last {
                list[i].lastMessage = last.kind == .text
                    ? last.body
                    : (last.kind == .image ? "画像" : "ファイル")
            }
        }
        self.contacts = list
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

struct ChatGroup: Identifiable, Hashable {
    let id: String
    var name: String
    var memberIds: [String]
}

struct ChatMessage: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case text, image, file
    }

    enum Delivery: String, Hashable {
        case sent, delivered, read
    }

    let id: String
    var body: String
    var mine: Bool
    var ts: Date
    var kind: Kind = .text
    var replyTo: String? = nil
    var delivery: Delivery = .sent
    /// Set for incoming group messages (nil in 1:1 chats).
    var senderName: String? = nil
}
