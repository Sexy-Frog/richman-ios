import Foundation
import SwiftUI
import UIKit
import UserNotifications
import Security
import CryptoKit
import UniformTypeIdentifiers
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
    /// Last shared position per contact (fed by `loc`/`loc_once`, shown on the map).
    @Published private(set) var places: [String: FriendPlace] = [:]
    /// Blocked contact ids (App Store UGC requirement — blocked peers can't be
    /// messaged and their inbound messages are dropped). Persisted in UserDefaults.
    @Published private(set) var blockedIds: Set<String> = []
    private let blockedKey = "rm.blocked"

    let crypto: CryptoProvider
    /// Non-nil only when Tor is up and the app is foreground. Every send/poll
    /// goes through this; nil means the chat stays local (Simulator/demo).
    private var relayTransport: RelayTransport?
    /// One actor for every send/poll so libsignal session operations are
    /// serialized (multiple actors would encrypt concurrently for one peer).
    private var relayServiceInstance: RelayService?
    private var pollTask: Task<Void, Never>?
    /// During a call the active peer is long-polled first for low latency.
    private var fastPeer: String?
    /// Call signaling/audio hooks, wired by RootView to `CallStore`.
    var onCallSignal: ((String, CallSignal) -> Void)?
    var onCallAudio: ((String, CallAudio) -> Void)?
    /// Invite mailboxes waiting for the first message (inviter side). When one
    /// is claimed, the sender becomes a contact and this box is dropped.
    private var pendingBoxes: Set<String> = []
    private var saveTask: Task<Void, Never>?
    private var loaded = false

    /// Demo/screenshot builds must stay deterministic, so they never read or
    /// write the sealed state file.
    private var persistenceEnabled: Bool { !DemoData.enabled }

    init(displayName: String,
         crypto: CryptoProvider = CryptoProviderFactory.make()) {
        self.displayName = displayName
        self.crypto = crypto
        if let saved = UserDefaults.standard.stringArray(forKey: blockedKey) {
            self.blockedIds = Set(saved)
        }
        if persistenceEnabled, let state = LocalStore.load() {
            contacts = state.contacts
            groups = state.groups
            messagesByPeer = state.messages
            groupMessages = state.groupMessages
            places = state.places
            pendingBoxes = Set(state.pendingBoxes)
            blockedIds = Set(state.blocked)
        }
        DemoData.seed(into: self)
        seedOfficialIfNeeded()
        let stored = UserDefaults.standard.object(forKey: "rm.retentionDays") as? Int
        purgeOldMessages(days: stored ?? 30)
        loaded = true
    }

    // MARK: sealed local persistence

    private func scheduleSave() {
        guard persistenceEnabled, loaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        LocalStore.save(
            LocalStore.State(
                contacts: contacts,
                groups: groups,
                messages: messagesByPeer,
                groupMessages: groupMessages,
                places: places,
                pendingBoxes: Array(pendingBoxes),
                blocked: Array(blockedIds)
            )
        )
    }

    var myId: String { crypto.myId }

    var totalUnread: Int {
        contacts.reduce(0) { $0 + $1.unread }
            + groups.reduce(0) { $0 + $1.unread }
    }

    func setActivePeer(_ peerId: String?) {
        activePeer = peerId
        if let peerId { markRead(peerId) }
    }

    func setActiveGroup(_ groupId: String?) {
        activeGroup = groupId
        if let groupId { markGroupRead(groupId) }
    }

    /// Chat currently on screen (read receipts / no unread while open).
    private var activePeer: String?
    private var activeGroup: String?
    private var sentReceipts: Set<String> = []
    /// Wired by RootView: current one-shot position for `/locate` replies.
    var currentLocationProvider: (() -> (latitude: Double, longitude: Double, accuracy: Double?)?)?

    /// True while the app has a working Tor → relay path.
    var relayReady: Bool { relayTransport != nil }

    /// Attach/detach the Tor transport (called on foreground and when Tor
    /// finishes bootstrapping). Detaching stops the receive loop.
    func attachRelay(_ transport: RelayTransport?) {
        if relayTransport == nil && transport == nil { return }
        relayTransport = transport
        relayServiceInstance = transport.map { RelayService(transport: $0, crypto: crypto) }
        pollTask?.cancel()
        pollTask = nil
        guard transport != nil else { return }
        startPolling()
    }

    private func relayService() -> RelayService? {
        relayServiceInstance
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                if self.fastPeer == nil {
                    // One empty poll per mailbox every 5s. During a call the
                    // fast path long-polls instead (see pollOnce).
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }

    /// Low-latency polling for the peer on an active call (long-poll with
    /// `wait`), so 300 ms ADPCM chunks do not sit in the mailbox.
    func setFastPolling(_ on: Bool, peerId: String?) {
        let peer = on ? peerId : nil
        guard fastPeer != peer else { return }
        fastPeer = peer
        startPolling()
    }

    /// Send one call signal / audio packet over the usual encrypted 1:1 path.
    func sendCallPayload(_ payload: Data, to peerId: String) {
        transmit(payload, to: peerId, markMid: "")
    }

    /// One pass over every mailbox we own: per-contact receive boxes plus
    /// invite boxes that no scanner has claimed yet.
    func pollOnce() async {
        guard let service = relayService() else { return }
        let wait = fastPeer == nil ? 0 : 15
        let peers = contacts
            .filter { !$0.official }
            .sorted { lhs, rhs in
                (lhs.id == fastPeer ? 0 : 1) < (rhs.id == fastPeer ? 0 : 1)
            }

        for peer in peers {
            guard let text = peer.recvBox,
                  let box = try? Base64URL.decode(text), box.count == 32 else { continue }
            guard let opened = try? await service.poll(
                box: box, knownSender: peer.id, wait: wait
            ) else {
                continue
            }
            for message in opened { await apply(message) }
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
                for message in opened { await apply(message) }
            }
        }
    }

    /// Apply a decrypted inbound message: learn the peer's reply mailbox,
    /// create a contact for a first message arriving on an invite box, then
    /// dispatch on the payload type.
    private func apply(_ opened: OpenedMessage) async {
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
            receive(
                from: opened.senderId,
                text: text.b,
                remoteId: text.mid,
                replyId: text.re,
                replyName: text.ren,
                replyText: text.ret
            )
        case .img?:
            guard let image = try? JSONDecoder().decode(
                ImageMessage.self, from: opened.payload
            ) else { return }
            await fetchMedia(
                id: image.id, key: image.k, nonce: image.n,
                peerId: opened.senderId, kind: .image,
                fileName: nil, remoteId: image.mid
            )
        case .file?:
            guard let file = try? JSONDecoder().decode(
                FileMessage.self, from: opened.payload
            ) else { return }
            await fetchMedia(
                id: file.id, key: file.k, nonce: file.n,
                peerId: opened.senderId, kind: .file,
                fileName: file.name, remoteId: file.mid
            )
        case .profile?:
            guard let profile = try? JSONDecoder().decode(
                ProfileMessage.self, from: opened.payload
            ) else { return }
            if let name = profile.n, !name.isEmpty,
               let index = contacts.firstIndex(where: { $0.id == opened.senderId }) {
                contacts[index].name = name
                scheduleSave()
            }
        case .ttl?:
            guard let ttl = try? JSONDecoder().decode(
                TtlMessage.self, from: opened.payload
            ) else { return }
            let seconds = Int(ttl.ms / 1000)
            UserDefaults.standard.set(seconds, forKey: "rm.ttl.\(opened.senderId)")
            purgeExpired(opened.senderId)
            appendSystem(opened.senderId, text: ttlSystemLabel(seconds))
        case .locReq?:
            guard let request = try? JSONDecoder().decode(
                LocationRequest.self, from: opened.payload
            ) else { return }
            // Same consent gate as the settings toggle; one-shot only.
            let sharing = (UserDefaults.standard.object(
                forKey: "rm.shareLocation"
            ) as? Bool) ?? true
            if sharing, let fix = currentLocationProvider?() {
                let reply = LocationMessage(
                    t: MessageType.locOnce.rawValue,
                    id: request.id,
                    lat: fix.latitude,
                    lon: fix.longitude,
                    acc: fix.accuracy,
                    ts: Int64(Date().timeIntervalSince1970 * 1000)
                )
                if let json = try? reply.toPayloadJSON() {
                    transmit(json, to: opened.senderId, markMid: "")
                }
            } else if let json = try? LocationDenied(why: "off").toPayloadJSON() {
                transmit(json, to: opened.senderId, markMid: "")
            }
        case .locDenied?:
            appendSystem(
                opened.senderId,
                text: "相手は位置情報を共有していません"
            )
        case .loc?, .locOnce?, .locUpdate?, .locStart?:
            guard let loc = try? JSONDecoder().decode(
                LocationMessage.self, from: opened.payload
            ) else { return }
            guard abs(loc.lat) <= 90, abs(loc.lon) <= 180 else { return }
            places[opened.senderId] = FriendPlace(
                latitude: loc.lat,
                longitude: loc.lon,
                accuracy: loc.acc,
                updatedAt: Date()
            )
            appendIncomingPlace(
                peerId: opened.senderId,
                text: "位置情報",
                remoteId: loc.id
            )
        case .locStop?:
            places.removeValue(forKey: opened.senderId)
            appendIncomingPlace(
                peerId: opened.senderId,
                text: "位置情報の共有が停止されました",
                remoteId: nil
            )
        case .groupInvite?:
            guard let invite = try? JSONDecoder().decode(
                GroupInviteMessage.self, from: opened.payload
            ) else { return }
            ensureGroup(
                invite.gid,
                name: invite.name,
                members: invite.members.map(\.id) + [opened.senderId]
            )
            if let index = groups.firstIndex(where: { $0.id == invite.gid }),
               groups[index].ownerId == nil,
               !invite.hub.isEmpty {
                groups[index].ownerId = invite.hub
            }
            appendGroupMessage(
                invite.gid,
                message: ChatMessage(
                    id: UUID().uuidString,
                    body: "\(invite.n ?? contact(opened.senderId)?.name ?? "友だち")がグループ「\(invite.name)」に招待しました",
                    mine: false,
                    ts: Date()
                )
            )
        case .groupMsg?:
            guard let groupMessage = try? JSONDecoder().decode(
                GroupMessage.self, from: opened.payload
            ) else { return }
            ensureGroup(groupMessage.gid, name: nil, members: [groupMessage.sender])
            if (groupMessage.kind == "img" || groupMessage.kind == "file"),
               let encoded = groupMessage.m,
               let manifest = try? MediaManifest.parse(encoded) {
                await fetchGroupMedia(
                    manifest,
                    groupId: groupMessage.gid,
                    kind: groupMessage.kind == "img" ? .image : .file,
                    senderName: groupMessage.n,
                    remoteId: groupMessage.mid
                )
            } else {
                appendGroupMessage(
                    groupMessage.gid,
                    message: ChatMessage(
                        id: UUID().uuidString,
                        body: groupMessage.b ?? "メッセージ",
                        mine: false,
                        ts: Date(),
                        senderName: groupMessage.n,
                        remoteId: groupMessage.mid
                    )
                )
            }
        case .groupAdd?, .groupRemove?, .groupLeave?:
            guard let membership = try? JSONDecoder().decode(
                GroupMembershipMessage.self, from: opened.payload
            ) else { return }
            handleMembership(membership)
        case .groupDel?:
            guard let deletion = try? JSONDecoder().decode(
                GroupDeleteMessage.self, from: opened.payload
            ) else { return }
            if deletion.ids.isEmpty {
                // Creator deletion: drop the whole group.
                removeGroupLocally(deletion.gid)
            } else {
                groupMessages[deletion.gid]?.removeAll { message in
                    deletion.ids.contains(message.id)
                        || (message.remoteId.map(deletion.ids.contains) ?? false)
                }
                scheduleSave()
            }
        case .callOffer?, .callAnswer?, .callEnd?:
            guard let signal = try? JSONDecoder().decode(
                CallSignal.self, from: opened.payload
            ) else { return }
            onCallSignal?(opened.senderId, signal)
        case .callAudio?:
            guard let audio = try? JSONDecoder().decode(
                CallAudio.self, from: opened.payload
            ) else { return }
            onCallAudio?(opened.senderId, audio)
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
        scheduleSave()
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
        scheduleSave()
    }

    func messages(for peerId: String) -> [ChatMessage] { messagesByPeer[peerId] ?? [] }

    func contact(_ peerId: String) -> Contact? { contacts.first { $0.id == peerId } }

    var blockedContacts: [Contact] {
        contacts.filter { blockedIds.contains($0.id) }
    }

    /// Change the display name and propagate it to existing contacts
    /// (`{"t":"profile","n":...}`). The official feed never gets a profile.
    func updateDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        displayName = trimmed
        UserDefaults.standard.set(trimmed, forKey: "rm.displayName")
        let profile = ProfileMessage(n: trimmed, av: 0)
        if let json = try? profile.toPayloadJSON() {
            for peer in contacts where !peer.official && peer.box != nil {
                transmit(json, to: peer.id, markMid: "")
            }
        }
        scheduleSave()
    }

    /// Delete the conversation but keep the contact (Android "トークを削除").
    func clearChat(_ peerId: String) {
        messagesByPeer[peerId] = []
        if let index = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[index].lastMessage = ""
            contacts[index].unread = 0
        }
        updateBadge()
        scheduleSave()
    }

    /// Append an outgoing message, then (on device, over Tor) seal it with
    /// libsignal and POST it to the peer's mailbox. Without a relay the message
    /// stays local, which is the Simulator/demo behaviour.
    func send(to peerId: String, text: String,
              kind: ChatMessage.Kind = .text,
              replyTo: String? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isBlocked(peerId) else { return }
        let mid = UUID().uuidString

        // `/locate` is a command, never visible text (Android parity).
        if kind == .text, Self.isLocateCommand(body) {
            messagesByPeer[peerId, default: []].append(
                ChatMessage(
                    id: mid, body: "位置情報をリクエストしました", mine: true, ts: Date()
                )
            )
            if let i = contacts.firstIndex(where: { $0.id == peerId }) {
                contacts[i].lastMessage = "位置情報をリクエスト"
            }
            scheduleSave()
            if let json = try? LocationRequest(id: mid).toPayloadJSON() {
                transmit(json, to: peerId, markMid: mid)
            }
            return
        }

        messagesByPeer[peerId, default: []].append(
            ChatMessage(id: mid, body: body, mine: true, ts: Date(),
                        kind: kind, replyTo: replyTo)
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = kind == .text ? body : (kind == .image ? "画像" : "ファイル")
        }
        objectWillChange.send()
        scheduleSave()

        guard kind == .text else { return }

        // Wire reply metadata so the peer can render the quote even without
        // the referenced message.
        var replyWireId: String?
        var replyName: String?
        var replyPreview: String?
        if let replyTo,
           let target = messagesByPeer[peerId]?.first(where: { $0.id == replyTo }) {
            replyWireId = target.remoteId ?? target.id
            replyName = target.mine ? displayName : contact(peerId)?.name
            let snippet: String
            switch target.kind {
            case .image: snippet = "画像"
            case .file: snippet = "ファイル"
            case .location: snippet = "位置情報"
            case .text: snippet = target.body
            }
            replyPreview = String(snippet.prefix(80))
        }

        let payload = TextMessage(
            b: body, n: displayName, ts: Int64(Date().timeIntervalSince1970 * 1000),
            mid: mid, exp: expiry(peerId),
            re: replyWireId, ren: replyName, ret: replyPreview
        )
        guard let json = try? payload.toPayloadJSON() else { return }
        transmit(json, to: peerId, markMid: mid)
    }

    static func isLocateCommand(_ text: String) -> Bool {
        let commands: Set<String> = [
            "/locate", "/loc", "/where", "/位置", "/いち",
        ]
        return commands.contains(
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /// Expiry timestamp for the peer's disappearing timer (nil = off).
    private func expiry(_ peerId: String) -> Int64? {
        let seconds = ttl(for: peerId)
        guard seconds > 0 else { return nil }
        return Int64(Date().addingTimeInterval(Double(seconds)).timeIntervalSince1970 * 1000)
    }

    /// Seal a payload with libsignal and POST it to the peer's mailbox. Does
    /// nothing (message stays local) without a live Tor relay.
    private func transmit(_ payload: Data, to peerId: String, markMid: String) {
        guard let peer = contact(peerId),
              let boxText = peer.box,
              let box = try? Base64URL.decode(boxText), box.count == 32,
              let service = relayService(),
              let replyBox = ensureRecvBox(peerId) else { return }
        Task { [weak self] in
            do {
                try await service.send(
                    payload: payload, to: peerId, box: box, replyBox: replyBox
                )
                self?.markMessage(peerId, mid: markMid, delivery: .delivered)
            } catch {
                self?.markMessage(peerId, mid: markMid, delivery: .sent)
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
        scheduleSave()
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
        scheduleSave()
        return box
    }

    /// Simulated transport acknowledgements (the relay loop will drive these).
    func markDelivered(_ peerId: String) {
        guard var list = messagesByPeer[peerId] else { return }
        for i in list.indices where list[i].mine && list[i].delivery == .sent {
            list[i].delivery = .delivered
        }
        messagesByPeer[peerId] = list
        scheduleSave()
    }

    func markMyMessagesRead(_ peerId: String) {
        guard var list = messagesByPeer[peerId] else { return }
        for i in list.indices where list[i].mine {
            list[i].delivery = .read
        }
        messagesByPeer[peerId] = list
        scheduleSave()
    }

    // MARK: message deletion

    /// Delete locally; for my own message the peer can be told to delete its
    /// copy too (`{"t":"del","ids":[mid]}`).
    func deleteMessage(_ message: ChatMessage, in peerId: String, everyone: Bool) {
        messagesByPeer[peerId]?.removeAll { $0.id == message.id }
        if everyone, message.mine {
            let payload = DeleteMessage(ids: [message.id])
            if let json = try? payload.toPayloadJSON() {
                transmit(json, to: peerId, markMid: "")
            }
        }
        scheduleSave()
    }

    // MARK: group media

    func sendImage(toGroup groupId: String, data: Data) {
        guard let group = group(groupId), let name = MediaStore.saveImage(data) else {
            return
        }
        let mid = UUID().uuidString
        groupMessages[groupId, default: []].append(
            ChatMessage(
                id: mid, body: "", mine: true, ts: Date(),
                kind: .image, remoteId: mid, mediaName: name
            )
        )
        scheduleSave()
        guard let transport = relayTransport, let blob = Self.sealBlob(data) else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let blobId = try await RelayClient(transport: transport)
                    .putBlob(blob.ciphertext)
                let manifest = MediaManifest(
                    id: blobId, k: blob.key, n: blob.nonce,
                    mime: "image/jpeg", sz: Int64(data.count)
                )
                try self.sendGroupManifest(
                    manifest, kind: "img", mid: mid, group: group
                )
            } catch {
                return
            }
        }
    }

    func sendFile(toGroup groupId: String, url: URL) {
        guard let group = group(groupId), let saved = MediaStore.saveFile(url),
              let blob = Self.sealBlob(saved.data) else { return }
        let mid = UUID().uuidString
        groupMessages[groupId, default: []].append(
            ChatMessage(
                id: mid, body: url.lastPathComponent, mine: true, ts: Date(),
                kind: .file, remoteId: mid, mediaName: saved.name,
                fileSize: saved.size
            )
        )
        scheduleSave()
        guard let transport = relayTransport else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let original = url.lastPathComponent
        Task { [weak self] in
            guard let self else { return }
            do {
                let blobId = try await RelayClient(transport: transport)
                    .putBlob(blob.ciphertext)
                let manifest = MediaManifest(
                    id: blobId, k: blob.key, n: blob.nonce, name: original,
                    mime: mime, sz: Int64(saved.data.count)
                )
                try self.sendGroupManifest(
                    manifest, kind: "file", mid: mid, group: group
                )
            } catch {
                return
            }
        }
    }

    private func sendGroupManifest(
        _ manifest: MediaManifest,
        kind: String,
        mid: String,
        group: ChatGroup
    ) throws {
        let message = GroupMessage(
            gid: group.id,
            kind: kind,
            m: try manifest.manifestString(),
            n: displayName,
            sender: crypto.myId,
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            mid: mid
        )
        let json = try message.toPayloadJSON()
        for member in group.memberIds where member != crypto.myId {
            transmit(json, to: member, markMid: "")
        }
    }

    private func fetchGroupMedia(
        _ manifest: MediaManifest,
        groupId: String,
        kind: ChatMessage.Kind,
        senderName: String,
        remoteId: String?
    ) async {
        guard let transport = relayTransport else { return }
        guard let blob = try? await RelayClient(transport: transport)
            .getBlob(id: manifest.id) else { return }
        guard let keyData = try? Base64URL.decode(manifest.k), keyData.count == 32,
              let nonceData = try? Base64URL.decode(manifest.n), nonceData.count == 12,
              let box = try? AES.GCM.SealedBox(combined: nonceData + blob),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else {
            return
        }
        let savedName: String
        let savedSize: Int
        if kind == .image {
            guard let saved = MediaStore.saveImage(plain) else { return }
            savedName = saved
            savedSize = plain.count
        } else {
            guard let saved = MediaStore.saveFileData(
                plain, name: manifest.name ?? "file"
            ) else { return }
            savedName = saved.name
            savedSize = saved.size
        }
        appendGroupMessage(
            groupId,
            message: ChatMessage(
                id: UUID().uuidString,
                body: kind == .file ? (manifest.name ?? "ファイル") : "",
                mine: false,
                ts: Date(),
                kind: kind,
                senderName: senderName,
                remoteId: remoteId,
                mediaName: savedName,
                fileSize: savedSize
            )
        )
    }

    /// Delete a group message locally, or for everyone when it is mine.
    func deleteGroupMessage(
        _ message: ChatMessage,
        in groupId: String,
        everyone: Bool = false
    ) {
        groupMessages[groupId]?.removeAll { $0.id == message.id }
        if everyone, message.mine, let group = group(groupId) {
            let payload = GroupDeleteMessage(
                gid: groupId,
                ids: [message.id],
                sender: crypto.myId,
                ts: Int64(Date().timeIntervalSince1970 * 1000)
            )
            if let json = try? payload.toPayloadJSON() {
                for member in group.memberIds where member != crypto.myId {
                    transmit(json, to: member, markMid: "")
                }
            }
        }
        scheduleSave()
    }

    /// Record an inbound message (will be called by the relay receive loop).
    func receive(
        from peerId: String,
        text: String,
        remoteId: String? = nil,
        replyId: String? = nil,
        replyName: String? = nil,
        replyText: String? = nil
    ) {
        guard !isBlocked(peerId) else { return }   // drop messages from blocked peers
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: UUID().uuidString, body: text, mine: false, ts: Date(),
                replyTo: replyId, remoteId: remoteId,
                replyName: replyName, replyText: replyText
            )
        )
        noteIncoming(peerId, preview: text, notify: true)
    }

    func markRead(_ peerId: String) {
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].unread = 0
            updateBadge()
            scheduleSave()
        }
        sendReadReceipts(peerId)
    }

    /// Ack the peer's inbound mids once (Android sends `{"t":"read","ids":[]}`).
    private func sendReadReceipts(_ peerId: String) {
        let mids = (messagesByPeer[peerId] ?? [])
            .filter { !$0.mine }
            .compactMap(\.remoteId)
            .filter { !sentReceipts.contains($0) }
        guard !mids.isEmpty else { return }
        sentReceipts.formUnion(mids)
        guard let json = try? ReadReceipt(ids: mids).toPayloadJSON() else { return }
        transmit(json, to: peerId, markMid: "")
    }

    func markGroupRead(_ groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[index].unread = 0
        updateBadge()
        scheduleSave()
    }

    /// Shared inbound bookkeeping: unread/notify, or immediate read if open.
    private func noteIncoming(
        _ peerId: String,
        preview: String,
        notify: Bool
    ) {
        let isOpen = activePeer == peerId
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = preview
            if !isOpen { contacts[i].unread += 1 }
        }
        updateBadge()
        scheduleSave()
        if isOpen {
            sendReadReceipts(peerId)
        } else if notify, UIApplication.shared.applicationState != .active {
            NotificationManager.shared.message(
                from: contact(peerId)?.name ?? "RichMan",
                preview: preview
            )
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
        scheduleSave()
    }

    /// Delete contacts and messages on this device. The peer's copy is untouched.
    func clearAllContacts() {
        let keep = contacts.first { $0.official }?.id
        contacts.removeAll { !$0.official }
        messagesByPeer = messagesByPeer.filter { $0.key == keep }
        pendingBoxes.removeAll()
        updateBadge()
        scheduleSave()
    }

    func removeContact(_ peerId: String) {
        guard !(contacts.first { $0.id == peerId }?.official ?? false) else { return }
        contacts.removeAll { $0.id == peerId }
        messagesByPeer.removeValue(forKey: peerId)
        scheduleSave()
    }

    /// Full local wipe (duress / repeated wrong PIN). Includes the official feed.
    func wipeAllLocal() {
        contacts.removeAll()
        groups.removeAll()
        messagesByPeer.removeAll()
        groupMessages.removeAll()
        blockedIds.removeAll()
        pendingBoxes.removeAll()
        saveTask?.cancel()
        UserDefaults.standard.removeObject(forKey: blockedKey)
        LocalStore.wipe()
        MediaStore.clearAll()
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
        scheduleSave()
        // Keep both ends' expiry in step (Android sends `{"t":"ttl","ms":N}`).
        if let json = try? TtlMessage(ms: Int64(seconds) * 1000).toPayloadJSON() {
            transmit(json, to: peerId, markMid: "")
        }
    }

    private func appendSystem(_ peerId: String, text: String) {
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: UUID().uuidString, body: text, mine: false, ts: Date()
            )
        )
        scheduleSave()
    }

    private func ttlSystemLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "消えるメッセージをオフにしました"
        case 3600: return "消えるメッセージ: 1時間"
        case 86_400: return "消えるメッセージ: 1日"
        case 604_800: return "消えるメッセージ: 7日"
        case 2_592_000: return "消えるメッセージ: 30日"
        default: return "消えるメッセージ: \(seconds)秒"
        }
    }

    func purgeExpired(_ peerId: String) {
        let seconds = ttl(for: peerId)
        guard seconds > 0, let list = messagesByPeer[peerId] else { return }
        let cutoff = Date().addingTimeInterval(-Double(seconds))
        let kept = list.filter { $0.ts > cutoff }
        if kept.count != list.count {
            messagesByPeer[peerId] = kept
            scheduleSave()
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

    /// Send my current position as a one-shot `loc_once` (user-initiated only;
    /// there is no background or covert tracking).
    func sendLocation(
        to peerId: String,
        latitude: Double,
        longitude: Double,
        accuracy: Double?
    ) {
        guard !isBlocked(peerId), !(contact(peerId)?.official ?? false) else { return }
        let mid = UUID().uuidString
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: mid, body: "位置情報", mine: true, ts: Date(), kind: .location
            )
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = "位置情報"
        }
        scheduleSave()

        let payload = LocationMessage(
            t: MessageType.locOnce.rawValue,
            id: mid,
            lat: latitude,
            lon: longitude,
            acc: accuracy,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        guard let json = try? payload.toPayloadJSON() else { return }
        transmit(json, to: peerId, markMid: mid)
    }

    /// Image: keep a local copy, then (over Tor) upload the AES-GCM ciphertext
    /// as a one-shot blob and send an `img` payload with the key/nonce. The
    /// relay only ever holds ciphertext.
    func sendImage(to peerId: String, data: Data) {
        guard !isBlocked(peerId), let name = MediaStore.saveImage(data) else { return }
        let mid = UUID().uuidString
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: mid, body: "", mine: true, ts: Date(),
                kind: .image, mediaName: name
            )
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = "画像"
        }
        scheduleSave()

        guard let transport = relayTransport, let blob = Self.sealBlob(data) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let blobId = try await RelayClient(transport: transport)
                    .putBlob(blob.ciphertext)
                var image = ImageMessage(
                    id: blobId, k: blob.key, n: blob.nonce,
                    mime: "image/jpeg", sz: Int64(data.count), mid: mid
                )
                image.exp = self.expiry(peerId)
                self.transmit(try image.toPayloadJSON(), to: peerId, markMid: mid)
            } catch {
                return // remains a local-only attachment
            }
        }
    }

    func sendFile(to peerId: String, url: URL) {
        guard !isBlocked(peerId), let saved = MediaStore.saveFile(url) else { return }
        let mid = UUID().uuidString
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: mid, body: saved.name, mine: true, ts: Date(),
                kind: .file, mediaName: saved.name, fileSize: saved.size
            )
        )
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = "ファイル"
        }
        scheduleSave()

        guard let transport = relayTransport, let blob = Self.sealBlob(saved.data) else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let original = url.lastPathComponent
        Task { [weak self] in
            guard let self else { return }
            do {
                let blobId = try await RelayClient(transport: transport)
                    .putBlob(blob.ciphertext)
                var file = FileMessage(
                    id: blobId, k: blob.key, n: blob.nonce, name: original,
                    mime: mime, sz: Int64(saved.data.count), mid: mid
                )
                file.exp = self.expiry(peerId)
                self.transmit(try file.toPayloadJSON(), to: peerId, markMid: mid)
            } catch {
                return
            }
        }
    }

    /// AES-256-GCM with a fresh key per blob. `combined` = nonce ‖ ct ‖ tag,
    /// which is exactly Android's image/file message layout once split.
    private static func sealBlob(_ data: Data)
        -> (ciphertext: Data, key: String, nonce: String)? {
        let key = SymmetricKey(size: .bits256)
        guard let box = try? AES.GCM.seal(data, using: key),
              let combined = box.combined, combined.count > 12 else { return nil }
        let nonce = combined.prefix(12)
        let ciphertext = combined.dropFirst(12)
        let keyData = key.withUnsafeBytes { Data($0) }
        return (
            Data(ciphertext),
            Base64URL.encode(keyData),
            Base64URL.encode(Data(nonce))
        )
    }

    /// Fetch, decrypt and store media from a received `img`/`file` message.
    private func fetchMedia(
        id: String,
        key: String,
        nonce: String,
        peerId: String,
        kind: ChatMessage.Kind,
        fileName: String?,
        remoteId: String?
    ) async {
        guard let transport = relayTransport else { return }
        guard let blob = try? await RelayClient(transport: transport).getBlob(id: id) else {
            return
        }
        guard let keyData = try? Base64URL.decode(key), keyData.count == 32,
              let nonceData = try? Base64URL.decode(nonce), nonceData.count == 12,
              let box = try? AES.GCM.SealedBox(combined: nonceData + blob),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else {
            return
        }

        let savedName: String
        let savedSize: Int
        if kind == .image {
            guard let saved = MediaStore.saveImage(plain) else { return }
            savedName = saved
            savedSize = plain.count
        } else {
            guard let saved = MediaStore.saveFileData(
                plain, name: fileName ?? "file"
            ) else { return }
            savedName = saved.name
            savedSize = saved.size
        }
        appendIncomingMedia(
            peerId, kind: kind, name: savedName,
            size: savedSize, remoteId: remoteId
        )
    }

    private func appendIncomingPlace(
        peerId: String,
        text: String,
        remoteId: String?
    ) {
        guard !isBlocked(peerId) else { return }
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: UUID().uuidString,
                body: text,
                mine: false,
                ts: Date(),
                kind: .location,
                remoteId: remoteId
            )
        )
        noteIncoming(peerId, preview: text, notify: true)
    }

    private func appendIncomingMedia(
        _ peerId: String,
        kind: ChatMessage.Kind,
        name: String,
        size: Int,
        remoteId: String?
    ) {
        guard !isBlocked(peerId) else { return }
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: UUID().uuidString,
                body: kind == .file ? name : "",
                mine: false,
                ts: Date(),
                kind: kind,
                remoteId: remoteId,
                mediaName: name,
                fileSize: size
            )
        )
        noteIncoming(
            peerId,
            preview: kind == .image ? "画像" : "ファイル",
            notify: true
        )
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
            memberIds: memberIds,
            ownerId: crypto.myId
        )
        groups.append(group)
        groupMessages[group.id] = []
        scheduleSave()
        sendInvites(for: group, to: group.memberIds)
        return group
    }

    private func memberList(of group: ChatGroup) -> [GroupMember] {
        group.memberIds.map { id in
            GroupMember(id: id, name: contact(id)?.name ?? "メンバー")
        }
    }

    private func invitePayload(for group: ChatGroup) -> Data? {
        let invite = GroupInviteMessage(
            gid: group.id,
            name: group.name,
            hub: crypto.myId,
            hub_box: "",
            hub_tag: "",
            members: memberList(of: group),
            n: displayName,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        return try? invite.toPayloadJSON()
    }

    private func sendInvites(for group: ChatGroup, to ids: [String]) {
        guard let json = invitePayload(for: group) else { return }
        for id in ids where id != crypto.myId {
            transmit(json, to: id, markMid: "")
        }
    }

    func send(toGroup id: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let group = self.group(id) else { return }
        let mid = UUID().uuidString
        groupMessages[id, default: []].append(
            ChatMessage(id: mid, body: body, mine: true, ts: Date(), remoteId: mid)
        )
        scheduleSave()

        let message = GroupMessage(
            gid: id,
            kind: "text",
            b: body,
            n: displayName,
            sender: crypto.myId,
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            mid: mid
        )
        guard let json = try? message.toPayloadJSON() else { return }
        for member in group.memberIds where member != crypto.myId {
            transmit(json, to: member, markMid: "")
        }
    }

    func receive(inGroup id: String, from sender: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        groupMessages[id, default: []].append(
            ChatMessage(
                id: UUID().uuidString, body: body, mine: false, ts: Date(), senderName: sender
            )
        )
        scheduleSave()
    }

    /// Creator: tell the members and remove it everywhere.
    func deleteGroup(_ id: String) {
        if let group = group(id) {
            let payload = GroupDeleteMessage(
                gid: id, sender: crypto.myId,
                ts: Int64(Date().timeIntervalSince1970 * 1000)
            )
            if let json = try? payload.toPayloadJSON() {
                for member in group.memberIds {
                    transmit(json, to: member, markMid: "")
                }
            }
        }
        removeGroupLocally(id)
    }

    private func removeGroupLocally(_ id: String) {
        groups.removeAll { $0.id == id }
        groupMessages.removeValue(forKey: id)
        scheduleSave()
    }

    func addMembers(_ ids: [String], to groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        let existing = Set(groups[index].memberIds)
        let added = ids.filter { !existing.contains($0) && $0 != crypto.myId }
        guard !added.isEmpty else { return }
        groups[index].memberIds.append(contentsOf: added)
        scheduleSave()

        let group = groups[index]
        // New members get the full invite; existing ones get a membership add.
        sendInvites(for: group, to: added)
        for newMember in added {
            let add = GroupMembershipMessage(
                t: MessageType.groupAdd.rawValue,
                gid: groupId,
                id: newMember,
                name: contact(newMember)?.name ?? "メンバー",
                n: displayName,
                ts: Int64(Date().timeIntervalSince1970 * 1000)
            )
            guard let json = try? add.toPayloadJSON() else { continue }
            for member in group.memberIds where member != crypto.myId && member != newMember {
                transmit(json, to: member, markMid: "")
            }
        }
    }

    func removeMember(_ id: String, from groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[index].memberIds.removeAll { $0 == id }
        scheduleSave()

        let remove = GroupMembershipMessage(
            t: MessageType.groupRemove.rawValue,
            gid: groupId,
            id: id,
            name: contact(id)?.name ?? "メンバー",
            n: displayName,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        guard let json = try? remove.toPayloadJSON() else { return }
        transmit(json, to: id, markMid: "")
        for member in groups[index].memberIds where member != crypto.myId {
            transmit(json, to: member, markMid: "")
        }
    }

    /// Create the group locally when a message arrives before/without an invite.
    private func ensureGroup(_ gid: String, name: String?, members: [String]) {
        if let index = groups.firstIndex(where: { $0.id == gid }) {
            if let name, !name.isEmpty { groups[index].name = name }
            var set = Set(groups[index].memberIds)
            for member in members where member != crypto.myId { set.insert(member) }
            groups[index].memberIds = Array(set)
        } else {
            let resolved = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            groups.append(
                ChatGroup(
                    id: gid,
                    name: (resolved?.isEmpty == false ? resolved! : "グループ"),
                    memberIds: members.filter { $0 != crypto.myId }
                )
            )
            groupMessages[gid] = groupMessages[gid] ?? []
        }
        scheduleSave()
    }

    private func handleMembership(_ membership: GroupMembershipMessage) {
        guard let index = groups.firstIndex(where: { $0.id == membership.gid }) else {
            return
        }
        switch membership.t {
        case MessageType.groupAdd.rawValue:
            if let id = membership.id, id != crypto.myId,
               !groups[index].memberIds.contains(id) {
                groups[index].memberIds.append(id)
            }
        case MessageType.groupRemove.rawValue, MessageType.groupLeave.rawValue:
            if let id = membership.id {
                // The creator leaving dissolves the group for everyone.
                if membership.t == MessageType.groupLeave.rawValue,
                   id == groups[index].ownerId {
                    deleteGroup(membership.gid)
                    return
                }
                groups[index].memberIds.removeAll { $0 == id }
            }
        default:
            break
        }
        scheduleSave()
    }

    private func appendGroupMessage(_ groupId: String, message: ChatMessage) {
        groupMessages[groupId, default: []].append(message)
        let isOpen = activeGroup == groupId
        if !message.mine, !isOpen,
           let index = groups.firstIndex(where: { $0.id == groupId }) {
            groups[index].unread += 1
        }
        updateBadge()
        scheduleSave()
        if !message.mine, !isOpen,
           UIApplication.shared.applicationState != .active {
            let preview: String
            switch message.kind {
            case .image: preview = "画像"
            case .file: preview = "ファイル"
            case .location: preview = "位置情報"
            case .text: preview = message.body
            }
            NotificationManager.shared.message(
                from: message.senderName ?? group(groupId)?.name ?? "グループ",
                preview: preview
            )
        }
    }

    /// Leave a group (members) — the creator deletes it for everyone instead.
    func leaveGroup(_ id: String) {
        guard let group = group(id) else { return }
        let payload = GroupMembershipMessage(
            t: MessageType.groupLeave.rawValue,
            gid: id,
            id: crypto.myId,
            name: displayName,
            n: displayName,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        if let json = try? payload.toPayloadJSON() {
            for member in group.memberIds {
                transmit(json, to: member, markMid: "")
            }
        }
        removeGroupLocally(id)
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
        scheduleSave()
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

struct Contact: Identifiable, Hashable, Codable {
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

struct ChatGroup: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var memberIds: [String]
    /// Creator's id; the creator can delete the group for everyone, members can
    /// only leave.
    var ownerId: String? = nil
    var unread: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, name, memberIds, ownerId, unread
    }

    init(id: String, name: String, memberIds: [String],
         ownerId: String? = nil, unread: Int = 0) {
        self.id = id
        self.name = name
        self.memberIds = memberIds
        self.ownerId = ownerId
        self.unread = unread
    }

    /// Older sealed state has no ownerId/unread keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        memberIds = try container.decode([String].self, forKey: .memberIds)
        ownerId = try container.decodeIfPresent(String.self, forKey: .ownerId)
        unread = try container.decodeIfPresent(Int.self, forKey: .unread) ?? 0
    }
}

/// A contact's last shared position (in-memory + sealed state).
struct FriendPlace: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var accuracy: Double?
    var updatedAt: Date
}

struct ChatMessage: Identifiable, Hashable, Codable {
    enum Kind: String, Hashable, Codable {
        case text, image, file, location
    }

    enum Delivery: String, Hashable, Codable {
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
    /// Inbound reply target metadata (survives even if the referenced message
    /// was already deleted locally).
    var replyName: String? = nil
    var replyText: String? = nil
    /// Local media file name (image/file messages).
    var mediaName: String? = nil
    var fileSize: Int? = nil
}
