import Foundation
import SwiftUI
import UIKit
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
        seedOfficialIfNeeded()
        let stored = UserDefaults.standard.object(forKey: "rm.retentionDays") as? Int
        purgeOldMessages(days: stored ?? 30)
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
        if UIApplication.shared.applicationState != .active {
            NotificationManager.shared.message(
                from: contact(peerId)?.name ?? "RichMan",
                preview: text
            )
        }
    }

    func markRead(_ peerId: String) {
        if let i = contacts.firstIndex(where: { $0.id == peerId }) { contacts[i].unread = 0 }
    }

    // MARK: data deletion (this device only)

    /// Delete every message on this device, keeping contacts and the official feed.
    func clearAllMessages() {
        let keep = contacts.first { $0.official }?.id
        messagesByPeer = messagesByPeer.filter { $0.key == keep }
        for i in contacts.indices {
            contacts[i].lastMessage = ""
            contacts[i].unread = 0
        }
    }

    /// Delete contacts and messages on this device. The peer's copy is untouched.
    func clearAllContacts() {
        let keep = contacts.first { $0.official }?.id
        contacts.removeAll { !$0.official }
        messagesByPeer = messagesByPeer.filter { $0.key == keep }
    }

    func removeContact(_ peerId: String) {
        guard !(contacts.first { $0.id == peerId }?.official ?? false) else { return }
        contacts.removeAll { $0.id == peerId }
        messagesByPeer.removeValue(forKey: peerId)
    }

    /// Full local wipe (duress / repeated wrong PIN). Includes the official feed.
    func wipeAllLocal() {
        contacts.removeAll()
        groups.removeAll()
        messagesByPeer.removeAll()
        groupMessages.removeAll()
        blockedIds.removeAll()
        UserDefaults.standard.removeObject(forKey: blockedKey)
    }

    // MARK: official account (one-way broadcast, local only)

    private func seedOfficialIfNeeded() {
        guard !contacts.contains(where: { $0.official }) else { return }
        let official = Contact(id: "official", name: "Richman", official: true)
        contacts.insert(official, at: 0)
        if let index = contacts.firstIndex(where: { $0.official }) {
            contacts[index].lastMessage = "ようこそ RichMan へ"
        }
        messagesByPeer[official.id] = [
            ChatMessage(
                id: "official-welcome",
                body: """
                RichMan へようこそ。

                ・メッセージ・画像・ファイル・通話は端末間で暗号化されます。
                ・位置情報は友達とだけ共有され、設定でいつでも停止できます。
                ・このアカウントは運営からの配信専用です（返信はできません）。
                """,
                mine: false,
                ts: Date().addingTimeInterval(-3600)
            ),
        ]
    }

    // MARK: disappearing messages

    func ttl(for peerId: String) -> Int {
        UserDefaults.standard.integer(forKey: "rm.ttl.\(peerId)")
    }

    func setTTL(_ seconds: Int, for peerId: String) {
        UserDefaults.standard.set(seconds, forKey: "rm.ttl.\(peerId)")
        purgeExpired(peerId)
    }

    func purgeExpired(_ peerId: String) {
        let seconds = ttl(for: peerId)
        guard seconds > 0, let list = messagesByPeer[peerId] else { return }
        let cutoff = Date().addingTimeInterval(-Double(seconds))
        let kept = list.filter { $0.ts > cutoff }
        if kept.count != list.count {
            messagesByPeer[peerId] = kept
        }
    }

    /// Global retention (Settings → データ). 0 keeps messages forever.
    func purgeOldMessages(days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        messagesByPeer = messagesByPeer.mapValues { $0.filter { $0.ts > cutoff } }
        groupMessages = groupMessages.mapValues { $0.filter { $0.ts > cutoff } }
    }

    // MARK: media

    func sendImage(to peerId: String, data: Data) {
        guard !isBlocked(peerId), let name = MediaStore.saveImage(data) else { return }
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: UUID().uuidString, body: "", mine: true, ts: Date(),
                kind: .image, mediaName: name
            )
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = "画像"
        }
    }

    func sendFile(to peerId: String, url: URL) {
        guard !isBlocked(peerId), let saved = MediaStore.saveFile(url) else { return }
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: UUID().uuidString, body: saved.name, mine: true, ts: Date(),
                kind: .file, mediaName: saved.name, fileSize: saved.size
            )
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = "ファイル"
        }
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
    var official: Bool = false
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
    /// Local media file name (image/file messages).
    var mediaName: String? = nil
    var fileSize: Int? = nil
}
