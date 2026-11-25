import Foundation
import SwiftUI
import UIKit
import UserNotifications
import Security
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
    /// Non-nil only when Tor is up and the app is foreground. Every send/poll
    /// goes through this; nil means the chat stays local (Simulator/demo).
    private var relayTransport: RelayTransport?
    private var pollTask: Task<Void, Never>?
    /// Invite mailboxes waiting for the first message (inviter side). When one
    /// is claimed, the sender becomes a contact and this box is dropped.
    private var pendingBoxes: Set<String> = []

    init(displayName: String,
         crypto: CryptoProvider = CryptoProviderFactory.make()) {
        self.displayName = displayName
        self.crypto = crypto
        if let saved = UserDefaults.standard.stringArray(forKey: blockedKey) {
            self.blockedIds = Set(saved)
        }
        DemoData.seed(into: self)
        seedOfficialIfNeeded()
        let stored = UserDefaults.standard.object(forKey: "rm.retentionDays") as? Int
        purgeOldMessages(days: stored ?? 30)
    }

    var myId: String { crypto.myId }

    var totalUnread: Int { contacts.reduce(0) { $0 + $1.unread } }

    /// True while the app has a working Tor → relay path.
    var relayReady: Bool { relayTransport != nil }

    /// Attach/detach the Tor transport (called on foreground and when Tor
    /// finishes bootstrapping). Detaching stops the receive loop.
    func attachRelay(_ transport: RelayTransport?) {
        if relayTransport == nil && transport == nil { return }
        relayTransport = transport
        pollTask?.cancel()
        pollTask = nil
        guard transport != nil else { return }
        startPolling()
    }

    private func relayService() -> RelayService? {
        guard let relayTransport else { return nil }
        return RelayService(transport: relayTransport, crypto: crypto)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                // One empty poll per mailbox every 5s. Long-polling would hold
                // one Tor circuit per contact open, which is worse for a phone.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// One pass over every mailbox we own: per-contact receive boxes plus
    /// invite boxes that no scanner has claimed yet.
    func pollOnce() async {
        guard let service = relayService() else { return }

        for peer in contacts where !peer.official {
            guard let text = peer.recvBox,
                  let box = try? Base64URL.decode(text), box.count == 32 else { continue }
            guard let opened = try? await service.poll(box: box, knownSender: peer.id) else {
                continue
            }
            for message in opened { apply(message) }
        }

        for text in pendingBoxes {
            guard let box = try? Base64URL.decode(text), box.count == 32 else {
                pendingBoxes.remove(text)
                continue
            }
            guard let opened = try? await service.poll(box: box, knownSender: nil) else {
                continue
            }
            if !opened.isEmpty {
                pendingBoxes.remove(text)
                for message in opened { apply(message) }
            }
        }
    }

    /// Apply a decrypted inbound message: learn the peer's reply mailbox,
    /// create a contact for a first message arriving on an invite box, then
    /// dispatch on the payload type.
    private func apply(_ opened: OpenedMessage) {
        if !contacts.contains(where: { $0.id == opened.senderId }) {
            // Only a text/first message may create a contact; receipts from a
            // stranger must not appear as a chat.
            guard opened.type == .text else { return }
            contacts.append(
                Contact(
                    id: opened.senderId,
                    name: "新規",
                    tag: nil,
                    box: opened.replyBox,
                    recvBox: Base64URL.encode(Self.randomBytes(32))
                )
            )
        }
        guard let index = contacts.firstIndex(where: { $0.id == opened.senderId }) else {
            return
        }
        if let reply = opened.replyBox, !reply.isEmpty {
            contacts[index].box = reply
        }

        switch opened.type {
        case .text?:
            guard let text = try? JSONDecoder().decode(TextMessage.self, from: opened.payload) else {
                return
            }
            if contacts[index].name == "新規", let name = text.n, !name.isEmpty {
                contacts[index].name = name
            }
            receive(from: opened.senderId, text: text.b, remoteId: text.mid)
        case .read?:
            markMyMessagesRead(opened.senderId)
        case .del?:
            guard let del = try? JSONDecoder().decode(DeleteMessage.self, from: opened.payload) else {
                return
            }
            messagesByPeer[opened.senderId]?.removeAll { message in
                del.ids.contains(message.id)
                    || (message.remoteId.map(del.ids.contains) ?? false)
            }
        default:
            break
        }
    }

    private func updateBadge() {
        UNUserNotificationCenter.current().setBadgeCount(
            totalUnread,
            withCompletionHandler: nil
        )
    }

    // MARK: blocking (App Store UGC safety)

    func isBlocked(_ peerId: String) -> Bool { blockedIds.contains(peerId) }

    func setBlocked(_ peerId: String, _ blocked: Bool) {
        if blocked { blockedIds.insert(peerId) } else { blockedIds.remove(peerId) }
        UserDefaults.standard.set(Array(blockedIds), forKey: blockedKey)
    }

    func messages(for peerId: String) -> [ChatMessage] { messagesByPeer[peerId] ?? [] }

    func contact(_ peerId: String) -> Contact? { contacts.first { $0.id == peerId } }

    /// Append an outgoing message, then (on device, over Tor) seal it with
    /// libsignal and POST it to the peer's mailbox. Without a relay the message
    /// stays local, which is the Simulator/demo behaviour.
    func send(to peerId: String, text: String,
              kind: ChatMessage.Kind = .text,
              replyTo: String? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isBlocked(peerId) else { return }
        let mid = UUID().uuidString
        messagesByPeer[peerId, default: []].append(
            ChatMessage(id: mid, body: body, mine: true, ts: Date(),
                        kind: kind, replyTo: replyTo)
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = kind == .text ? body : (kind == .image ? "画像" : "ファイル")
        }
        objectWillChange.send()

        guard kind == .text,
              let peer = contact(peerId),
              let boxText = peer.box,
              let box = try? Base64URL.decode(boxText), box.count == 32,
              let service = relayService(),
              let replyBox = ensureRecvBox(peerId) else { return }
        let ttl = ttl(for: peerId)
        let exp = ttl > 0
            ? Int64((Date().addingTimeInterval(Double(ttl)).timeIntervalSince1970) * 1000)
            : nil
        let payload = TextMessage(
            b: body, n: displayName, ts: Int64(Date().timeIntervalSince1970 * 1000),
            mid: mid, exp: exp
        )
        Task { [weak self] in
            do {
                let json = try payload.toPayloadJSON()
                try await service.send(
                    payload: json, to: peerId, box: box, replyBox: replyBox
                )
                self?.markMessage(peerId, mid: mid, delivery: .delivered)
            } catch {
                self?.markMessage(peerId, mid: mid, delivery: .sent)
            }
        }
    }

    private func markMessage(
        _ peerId: String, mid: String, delivery: ChatMessage.Delivery
    ) {
        guard var list = messagesByPeer[peerId],
              let index = list.firstIndex(where: { $0.id == mid }) else { return }
        list[index].delivery = delivery
        messagesByPeer[peerId] = list
    }

    /// My receive mailbox for this peer (32 random bytes, base64url). The peer
    /// learns it from the `rb` stamped on my messages.
    private func ensureRecvBox(_ peerId: String) -> String? {
        guard let index = contacts.firstIndex(where: { $0.id == peerId }) else {
            return nil
        }
        if let existing = contacts[index].recvBox { return existing }
        let box = Base64URL.encode(Self.randomBytes(32))
        contacts[index].recvBox = box
        return box
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
    func receive(from peerId: String, text: String, remoteId: String? = nil) {
        guard !isBlocked(peerId) else { return }   // drop messages from blocked peers
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: UUID().uuidString, body: text, mine: false, ts: Date(),
                remoteId: remoteId
            )
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = text
            contacts[i].unread += 1
        }
        updateBadge()
        if UIApplication.shared.applicationState != .active {
            NotificationManager.shared.message(
                from: contact(peerId)?.name ?? "RichMan",
                preview: text
            )
        }
    }

    func markRead(_ peerId: String) {
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].unread = 0
            updateBadge()
        }
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
        updateBadge()
    }

    /// Delete contacts and messages on this device. The peer's copy is untouched.
    func clearAllContacts() {
        let keep = contacts.first { $0.official }?.id
        contacts.removeAll { !$0.official }
        messagesByPeer = messagesByPeer.filter { $0.key == keep }
        updateBadge()
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
        pendingBoxes.removeAll()
        UserDefaults.standard.removeObject(forKey: blockedKey)
        crypto.wipeLocalState()
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

    func addMembers(_ ids: [String], to groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        var members = Set(groups[index].memberIds)
        members.formUnion(ids)
        groups[index].memberIds = Array(members)
    }

    func removeMember(_ id: String, from groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[index].memberIds.removeAll { $0 == id }
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

    /// Local invite for mock / no-Tor builds. It is self-contained (no relay
    /// round-trip); the real build uses `makeRelayInvite`.
    func makeInvite() throws -> String {
        let box = Self.randomBytes(32)
        return String(
            decoding: try crypto.buildInviteBundle(displayName: displayName, box: box),
            as: UTF8.self
        )
    }

    /// Real one-shot invite (docs/PROTOCOL.md §2): mint a QR-only AES key, seal
    /// the prekey bundle, store the opaque blob on the relay, and return the QR
    /// that carries `{v,id,n,tag,box,k,t}`. Only the scanner can open the blob.
    func makeRelayInvite(using transport: RelayTransport) async throws -> String {
        let box = Self.randomBytes(32)
        let bundle = try crypto.buildInviteBundle(displayName: displayName, box: box)
        // Throws for the mock provider (its JSON has no prekey material), which
        // makes the caller fall back to the local invite.
        let material = try PrekeyBundle.decode(bundle)
        let key = Self.randomBytes(32)
        let sealed = try crypto.sealInvite(bundle, key: key)
        let envelope = try JSONSerialization.data(
            withJSONObject: ["e": Base64URL.encode(sealed)]
        )
        let token = try await RelayClient(transport: transport).putInvite(bundle: envelope)
        pendingBoxes.insert(material.box)
        let qr = QRInvite(
            id: material.id,
            n: material.n,
            tag: material.tag,
            box: material.box,
            k: Base64URL.encode(key),
            t: token
        )
        return String(decoding: try JSONEncoder().encode(qr), as: UTF8.self)
    }

    /// Add a contact from a scanned/pasted invite. With a transport this runs
    /// the full flow — fetch the sealed bundle by token, unseal with the QR key,
    /// cross-check id/tag/box, then X3DH. Without one (Simulator) it records the
    /// contact from the QR alone.
    @discardableResult
    func addFriend(inviteText: String, using transport: RelayTransport? = nil) async throws -> Contact {
        let qr = try QRInvite.parse(inviteText)
        try qr.checkNotSelf(localId: crypto.myId)
        if let existing = contact(qr.id) { return existing }

        var name = qr.n
        if let transport {
            guard let key = try? Base64URL.decode(qr.k), key.count == 32 else {
                throw InviteError.malformed
            }
            let raw = try await RelayClient(transport: transport).fetchInvite(token: qr.t)
            guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let encoded = obj["e"] as? String,
                  let sealed = try? Base64URL.decode(encoded) else {
                throw InviteError.malformed
            }
            let bundle = try crypto.openSealedInvite(sealed, key: key)
            let material = try PrekeyBundle.decode(bundle)
            try material.validate(against: qr)
            try crypto.startSession(peerId: material.id, bundle: bundle)
            if !material.n.isEmpty { name = material.n }
        }

        let c = Contact(
            id: qr.id,
            name: name.isEmpty ? "名前未設定" : name,
            tag: qr.tag,
            box: qr.box
        )
        contacts.append(c)
        return c
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        return data
    }
}

// MARK: shared models (single source of truth for the screens)

struct Contact: Identifiable, Hashable {
    let id: String          // base64url identity
    var name: String
    var lastMessage: String = ""
    var unread: Int = 0
    var official: Bool = false
    /// base64url routing tag (16B) and the peer's send mailbox (32B) from the
    /// invite (updated from the `rb` on their messages).
    var tag: String? = nil
    var box: String? = nil
    /// My receive mailbox for this peer (32B, base64url); polled and stamped as
    /// `rb` on every message I send them.
    var recvBox: String? = nil
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
    /// The sender's wire message id, kept for delete-for-everyone receipts.
    var remoteId: String? = nil
    /// Local media file name (image/file messages).
    var mediaName: String? = nil
    var fileSize: Int? = nil
}
