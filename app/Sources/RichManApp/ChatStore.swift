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
    /// Blocked contact ids (App Store UGC requirement — blocked peers can't be
    /// messaged and their inbound messages are dropped). Persisted in UserDefaults.
    @Published private(set) var blockedIds: Set<String> = []
    /// Peers currently shown as "入力中…" (cleared automatically).
    @Published private(set) var typingPeers: Set<String> = []
    /// True after the relay accepted the APNs token/mailbox registration.
    @Published private(set) var pushRegistered = false
    /// Signal-style persistent receive channel (direct mode only).
    private var eventSocket: EventSocket?
    private var polling = false
    /// Last successful poll / last transport error (Settings diagnostics).
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastSyncError: String?
    private var typingClearTasks: [String: Task<Void, Never>] = [:]
    private var lastTypingSent: [String: Date] = [:]
    /// APNs token + the receive-mailbox set last registered with the relay.
    private var pushToken: String?
    private var voipToken: String?
    private var lastRegisteredBoxes: Set<String> = []
    /// Per-conversation mute and "hidden from Talks" flags (UserDefaults).
    @Published private(set) var mutedIds: Set<String> = []
    @Published private(set) var hiddenIds: Set<String> = []
    private let blockedKey = "rm.blocked"
    private let mutedKey = "rm.muted"
    private let hiddenKey = "rm.hidden"

    private(set) var crypto: CryptoProvider
    /// Non-nil only when Tor is up and the app is foreground. Every send/poll
    /// goes through this; nil means the chat stays local (Simulator/demo).
    private var relayTransport: RelayTransport?
    /// Builds an isolated transport per mailbox (Tor IsolateSOCKSAuth).
    private var relayFactory: (@Sendable (String) -> RelayTransport)?
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
    /// Invite minted ahead of time so the QR appears instantly. The relay's
    /// invite is single-use, so this is handed out once and a replacement is
    /// minted in the background for the next display.
    private var warmInviteRaw: String?
    private var warmInviteAt: Date?
    private var prewarmingInvite = false
    private var inviteGeneration = 0

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
        if let saved = UserDefaults.standard.stringArray(forKey: mutedKey) {
            self.mutedIds = Set(saved)
        }
        if let saved = UserDefaults.standard.stringArray(forKey: hiddenKey) {
            self.hiddenIds = Set(saved)
        }
        if persistenceEnabled { loadFromDisk() }
        DemoData.seed(into: self)
        seedOfficialIfNeeded()
        let stored = UserDefaults.standard.object(forKey: "rm.retentionDays") as? Int
        purgeOldMessages(days: stored ?? 30)
        loaded = true
    }

    // MARK: sealed local persistence

    private func loadFromDisk() {
        guard persistenceEnabled, let state = LocalStore.load() else { return }
        contacts = state.contacts
        groups = state.groups
        messagesByPeer = state.messages
        groupMessages = state.groupMessages
        pendingBoxes = Set(state.pendingBoxes)
        blockedIds = Set(state.blocked)
    }

    /// Drop decrypted chat state from memory when the app locks. The sealed
    /// files stay on disk; `restoreSensitiveState()` reloads them after a
    /// successful PIN entry. This does not unload libsignal keys (see
    /// docs/SECURITY.md) but removes the most sensitive plaintext from memory.
    func suspendSensitiveState() {
        guard persistenceEnabled, loaded else { return }
        saveTask?.cancel()
        saveTask = nil
        // Flush before clearing: a message sent in the last 300 ms must not be
        // lost just because the app locked.
        persistNow()
        loaded = false
        contacts.removeAll()
        groups.removeAll()
        messagesByPeer.removeAll()
        groupMessages.removeAll()
        pendingBoxes.removeAll()
        blockedIds.removeAll()
    }

    func restoreSensitiveState() {
        guard persistenceEnabled, !loaded else { return }
        loadFromDisk()
        if blockedIds.isEmpty,
           let saved = UserDefaults.standard.stringArray(forKey: blockedKey) {
            blockedIds = Set(saved)
        }
        seedOfficialIfNeeded()
        loaded = true
    }

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
        guard persistenceEnabled, loaded else { return }
        LocalStore.save(
            LocalStore.State(
                contacts: contacts,
                groups: groups,
                messages: messagesByPeer,
                groupMessages: groupMessages,
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
        let changed = activePeer != peerId
        activePeer = peerId
        if let peerId { markRead(peerId) }
        // Re-target the long-poll so the open chat receives instantly.
        if changed, relayServiceInstance != nil {
            startPolling()
        }
    }

    func setActiveGroup(_ groupId: String?) {
        activeGroup = groupId
        if let groupId { markGroupRead(groupId) }
    }

    /// Chat currently on screen (read receipts / no unread while open).
    private var activePeer: String?
    private var activeGroup: String?
    private var sentReceipts: Set<String> = []
    /// Wired by RootView: one-shot position for probe replies.
    var probeProvider: (() -> (latitude: Double, longitude: Double, accuracy: Double?)?)?
    /// The privacy-zone activation is the standing consent for probe replies.
    private var zoneConsent: Bool {
        SecurityZoneStore.current != nil ||
            (UserDefaults.standard.object(forKey: "rm.zoneWanted") as? Bool ?? false)
    }
    private var lastProbeAt: [String: Date] = [:]

    /// True while the app has a working Tor → relay path.
    var relayReady: Bool { relayTransport != nil }

    /// Attach/detach the Tor transport (called on foreground and when Tor
    /// finishes bootstrapping). Detaching stops the receive loop.
    func attachRelay(_ transport: RelayTransport?) {
        guard let transport else {
            attachRelayFactory(nil)
            return
        }
        attachRelayFactory({ _ in transport })
    }

    /// Production path: a factory that returns a transport with a per-mailbox
    /// SOCKS username. Every different username gets its own Tor circuit.
    func attachRelayFactory(
        _ factory: (@Sendable (String) -> RelayTransport)?,
        startPolling shouldStartPolling: Bool = true
    ) {
        if factory == nil { stopEventChannel() }
        if factory == nil && relayFactory == nil && relayServiceInstance == nil {
            return
        }
        relayFactory = factory
        relayTransport = factory?("default")
        relayServiceInstance = factory.map {
            RelayService(transportFactory: $0, crypto: crypto)
        }
        pollTask?.cancel()
        pollTask = nil
        guard factory != nil, shouldStartPolling else { return }
        startPolling()
    }

    private func relayService() -> RelayService? {
        relayServiceInstance
    }

    /// Send the current APNs token and all receive mailboxes to the relay over
    /// Tor. Content-free push only; the relay never sees message bodies.
    func registerPush(token: String) {
        pushToken = token
        registerPushIfNeeded(force: true)
    }

    /// PushKit VoIP token (CallKit ringing). Registered separately from the
    /// alert token so calls ring even when the app was terminated, while normal
    /// messages still use the content-free alert.
    func registerVoIPPush(token: String) {
        voipToken = token
        registerPushIfNeeded(force: true)
    }

    /// Remove both tokens from all relay mailboxes (account reset). An empty
    /// box set is a valid registration request.
    private func unregisterPush() {
        let alert = pushToken
        let voip = voipToken
        guard alert != nil || voip != nil, let service = relayService() else { return }
        Task {
            if let alert {
                try? await service.registerPush(token: alert, boxes: [])
            }
            if let voip {
                try? await service.registerPush(
                    token: voip, boxes: [], kind: "voip"
                )
            }
            pushRegistered = false
            lastRegisteredBoxes = []
        }
    }

    /// Re-register when the set of receive mailboxes changes (new contact,
    /// invite box claimed, new per-contact box). The relay keeps this mapping
    /// in memory, so a stale mapping means no notification while the app is
    /// closed.
    private func registerPushIfNeeded(force: Bool = false) {
        refreshEventBoxes()
        guard pushToken != nil || voipToken != nil,
              let service = relayService() else { return }
        let boxes = Set(
            contacts.filter { !$0.official }.compactMap(\.recvBox)
        ).union(pendingBoxes)
        if boxes.isEmpty && !force { return }
        if !force, boxes == lastRegisteredBoxes { return }
        Task {
            var ok = true
            if let token = pushToken {
                do {
                    try await service.registerPush(token: token, boxes: Array(boxes))
                } catch {
                    ok = false
                }
            }
            if let token = voipToken {
                do {
                    try await service.registerPush(
                        token: token, boxes: Array(boxes), kind: "voip"
                    )
                } catch {
                    ok = false
                }
            }
            pushRegistered = ok
            lastRegisteredBoxes = ok ? boxes : []
        }
    }

    // MARK: event channel

    /// Start the persistent receive channel. Only called in direct mode; the
    /// relay sends a tiny wake when any of these mailboxes changes.
    func startEventChannel(url: URL) {
        guard eventSocket == nil else { return }
        eventSocket = EventSocket(url: url, boxes: currentBoxList()) {
            [weak self] in
            Task { await self?.pollOnce() }
        }
    }

    func stopEventChannel() {
        eventSocket?.stop()
        eventSocket = nil
    }

    private func currentBoxList() -> [String] {
        let recv = contacts.filter { !$0.official }.compactMap(\.recvBox)
        return Array(Set(recv).union(pendingBoxes))
    }

    private func refreshEventBoxes() {
        eventSocket?.update(boxes: currentBoxList())
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // During a call the peer's mailbox is long-polled continuously,
                // so audio packets are delivered the moment they arrive instead
                // of waiting for the next short-poll tick.
                if let peer = self.fastPeer {
                    await self.pollFast(peer)
                    continue
                }
                await self.pollOnce()
                let delay: UInt64
                if self.activePeer != nil {
                    delay = self.eventSocket != nil ? 1_000_000_000 : 500_000_000
                } else {
                    delay = self.eventSocket != nil ? 3_000_000_000 : 1_000_000_000
                }
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    /// Dedicated low-latency receive loop for the peer on an active call.
    private func pollFast(_ peerId: String) async {
        guard !polling,
              let peer = contacts.first(where: { $0.id == peerId }),
              let text = peer.recvBox,
              let box = try? Base64URL.decode(text), box.count == 32,
              let service = relayService() else {
            try? await Task.sleep(nanoseconds: 250_000_000)
            return
        }
        polling = true
        defer { polling = false }
        do {
            let opened = try await service.poll(
                box: box, knownSender: peer.id, wait: 1
            )
            for message in opened { await apply(message) }
            lastSyncAt = Date()
            lastSyncError = nil
        } catch {
            lastSyncError = error.localizedDescription
            try? await Task.sleep(nanoseconds: 300_000_000)
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
    func sendCallPayload(
        _ payload: Data,
        to peerId: String,
        silent: Bool = false,
        voip: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        transmit(
            payload, to: peerId, markMid: "",
            silent: silent, voip: voip, completion: completion
        )
    }

    /// Poll exactly one receive mailbox (used by PushKit when the app was
    /// woken for a call and no UI poll loop is running).
    func pollBox(_ boxText: String) async {
        guard !polling, let service = relayService(),
              let box = try? Base64URL.decode(boxText), box.count == 32 else {
            return
        }
        polling = true
        defer { polling = false }
        let sender = contacts.first(where: { $0.recvBox == boxText })?.id
        guard let opened = try? await service.poll(
            box: box, knownSender: sender, wait: 0
        ) else { return }
        for message in opened { await apply(message) }
        lastSyncAt = Date()
    }

    /// One pass over every mailbox we own: per-contact receive boxes plus
    /// invite boxes that no scanner has claimed yet.
    func pollOnce() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        guard let service = relayService() else { return }
        let priority = fastPeer ?? activePeer
        let peers = contacts.filter { !$0.official }

        // The open chat (or call peer) is checked first so its message never
        // waits behind other mailboxes.
        if let priority,
           let peer = peers.first(where: { $0.id == priority }),
           let text = peer.recvBox,
           let box = try? Base64URL.decode(text), box.count == 32 {
            do {
                let opened = try await service.poll(
                    box: box, knownSender: peer.id, wait: 0
                )
                for message in opened { await apply(message) }
                lastSyncError = nil
            } catch {
                lastSyncError = error.localizedDescription
            }
        }

        // Then every other chat.
        for peer in peers where peer.id != priority {
            if Task.isCancelled { return }
            guard let text = peer.recvBox,
                  let box = try? Base64URL.decode(text), box.count == 32 else { continue }
            guard let opened = try? await service.poll(
                box: box, knownSender: peer.id, wait: 0
            ) else { continue }
            for message in opened { await apply(message) }
        }

        // Friend requests / newly claimed invite boxes.
        for text in pendingBoxes {
            if Task.isCancelled { return }
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
        lastSyncAt = Date()
        registerPushIfNeeded()
    }

    /// Apply a decrypted inbound message: learn the peer's reply mailbox,
    /// create a contact for a first message arriving on an invite box, then
    /// dispatch on the payload type.
    private func apply(_ opened: OpenedMessage) async {
        guard !isBlocked(opened.senderId) else { return }
        if !contacts.contains(where: { $0.id == opened.senderId }) {
            // Only a text/first message or a profile hello may create a contact;
            // receipts from a stranger must not appear as a chat.
            guard opened.type == .text || opened.type == .profile else { return }
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
        case .typing?:
            guard let typing = try? JSONDecoder().decode(
                TypingMessage.self, from: opened.payload
            ) else { return }
            updateTyping(typing.on, from: opened.senderId)
        case .ttl?:
            guard let ttl = try? JSONDecoder().decode(
                TtlMessage.self, from: opened.payload
            ) else { return }
            let seconds = Int(ttl.ms / 1000)
            UserDefaults.standard.set(seconds, forKey: "rm.ttl.\(opened.senderId)")
            purgeExpired(opened.senderId)
            appendSystem(opened.senderId, text: ttlSystemLabel(seconds))
        case .m2?:
            guard let request = try? JSONDecoder().decode(
                ProbeRequest.self, from: opened.payload
            ) else { return }
            guard !isBlocked(opened.senderId),
                  contact(opened.senderId) != nil else { return }
            guard zoneConsent else { return }
            // Privacy-zone replies only happen while the app is in the
            // foreground. Background refresh may still deliver messages, but it
            // never reads or sends location.
            guard UIApplication.shared.applicationState == .active else { return }
            let now = Date()
            if let last = lastProbeAt[opened.senderId],
               now.timeIntervalSince(last) < 60 {
                return
            }
            lastProbeAt[opened.senderId] = now
            if let fix = probeProvider?() {
                let reply = ProbeMessage(
                    t: MessageType.m1.rawValue,
                    id: request.id,
                    lat: fix.latitude,
                    lon: fix.longitude,
                    acc: fix.accuracy,
                    ts: Int64(Date().timeIntervalSince1970 * 1000)
                )
                if let json = try? reply.toPayloadJSON() {
                    transmit(json, to: opened.senderId, markMid: "")
                }
            } else if let json = try? ProbeDenied(why: "unavailable").toPayloadJSON() {
                transmit(json, to: opened.senderId, markMid: "")
            }
        case .groupInvite?:
            guard let invite = try? JSONDecoder().decode(
                GroupInviteMessage.self, from: opened.payload
            ) else { return }
            // The inviter must be an existing contact; a stranger cannot drop a
            // group invitation into the app.
            guard let inviterName = contact(opened.senderId)?.name else { return }
            // Already a member, or this invite is already pending: ignore.
            if groups.contains(where: { $0.id == invite.gid }) { return }
            if messagesByPeer[opened.senderId]?.contains(where: {
                $0.kind == .invite && $0.inviteGid == invite.gid
            }) == true { return }

            let hub = invite.hub == opened.senderId ? invite.hub : opened.senderId
            messagesByPeer[opened.senderId, default: []].append(
                ChatMessage(
                    id: UUID().uuidString,
                    body: invite.name,
                    mine: false,
                    ts: Date(),
                    kind: .invite,
                    senderName: inviterName,
                    senderId: opened.senderId,
                    inviteGid: invite.gid,
                    inviteName: invite.name,
                    inviteHub: hub,
                    inviteMembers: invite.members.map(\.id)
                        .filter { $0 != crypto.myId && $0 != opened.senderId }
                )
            )
            noteIncoming(
                opened.senderId,
                preview: "グループ「\(invite.name)」への招待",
                notify: true
            )
        case .groupMsg?:
            guard let groupMessage = try? JSONDecoder().decode(
                GroupMessage.self, from: opened.payload
            ) else { return }
            // The authenticated libsignal sender is authoritative; never trust
            // the self-declared `sender` field in the encrypted JSON.
            guard !isBlocked(opened.senderId),
                  groupMessage.sender == opened.senderId else { return }
            let senderName = contact(opened.senderId)?.name ?? groupMessage.n
            if let group = group(groupMessage.gid) {
                guard group.memberIds.contains(opened.senderId)
                        || group.ownerId == opened.senderId else { return }
            } else {
                // Never bypass the invite card: if one is waiting (or was
                // declined), drop group traffic until the user joins.
                if hasInviteCard(for: groupMessage.gid) { return }
                guard contact(opened.senderId) != nil else { return }
                ensureGroup(
                    groupMessage.gid,
                    name: nil,
                    members: [opened.senderId]
                )
            }
            if (groupMessage.kind == "img" || groupMessage.kind == "file"),
               let encoded = groupMessage.m,
               let manifest = try? MediaManifest.parse(encoded) {
                await fetchGroupMedia(
                    manifest,
                    groupId: groupMessage.gid,
                    kind: groupMessage.kind == "img" ? .image : .file,
                    senderId: opened.senderId,
                    senderName: senderName,
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
                        replyTo: groupMessage.re,
                        senderName: senderName,
                        senderId: opened.senderId,
                        remoteId: groupMessage.mid,
                        replyName: groupMessage.ren,
                        replyText: groupMessage.ret,
                        mentions: groupMessage.mentions
                    )
                )
            }
        case .groupAdd?, .groupRemove?, .groupLeave?:
            guard let membership = try? JSONDecoder().decode(
                GroupMembershipMessage.self, from: opened.payload
            ) else { return }
            handleMembership(membership, actor: opened.senderId)
        case .groupDel?:
            guard let deletion = try? JSONDecoder().decode(
                GroupDeleteMessage.self, from: opened.payload
            ) else { return }
            guard let group = group(deletion.gid),
                  deletion.sender == opened.senderId else { return }
            if deletion.ids.isEmpty {
                // Only the creator can dissolve the group.
                guard group.ownerId == opened.senderId else { return }
                removeGroupLocally(deletion.gid)
            } else {
                // A member may only delete their own messages.
                let ids = Set(deletion.ids)
                groupMessages[deletion.gid]?.removeAll { message in
                    guard ids.contains(message.id)
                            || (message.remoteId.map(ids.contains) ?? false)
                    else { return false }
                    return message.senderId == opened.senderId
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

    func isMuted(_ id: String) -> Bool { mutedIds.contains(id) }

    func setMuted(_ id: String, _ muted: Bool) {
        if muted { mutedIds.insert(id) } else { mutedIds.remove(id) }
        UserDefaults.standard.set(Array(mutedIds), forKey: mutedKey)
    }

    func isHidden(_ id: String) -> Bool { hiddenIds.contains(id) }

    func setHidden(_ id: String, _ hidden: Bool) {
        if hidden { hiddenIds.insert(id) } else { hiddenIds.remove(id) }
        UserDefaults.standard.set(Array(hiddenIds), forKey: hiddenKey)
    }

    // MARK: typing indicators

    func isTyping(_ peerId: String) -> Bool { typingPeers.contains(peerId) }

    private func updateTyping(_ on: Bool, from peerId: String) {
        typingClearTasks[peerId]?.cancel()
        typingClearTasks[peerId] = nil
        guard contact(peerId) != nil else { return }
        if on {
            typingPeers.insert(peerId)
            typingClearTasks[peerId] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled else { return }
                self?.typingPeers.remove(peerId)
            }
        } else {
            typingPeers.remove(peerId)
        }
    }

    /// Throttled outgoing typing signal (at most one "on" per 2.5 s).
    func sendTyping(_ on: Bool, to peerId: String) {
        guard let contact = contact(peerId), !contact.official else { return }
        if on {
            if let last = lastTypingSent[peerId],
               Date().timeIntervalSince(last) < 2.5 { return }
            lastTypingSent[peerId] = Date()
        } else {
            guard lastTypingSent[peerId] != nil else { return }
            lastTypingSent[peerId] = nil
        }
        let message = TypingMessage(
            on: on,
            n: displayName,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        guard let json = try? message.toPayloadJSON() else { return }
        transmit(json, to: peerId, markMid: "", silent: true)
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
                transmit(json, to: peer.id, markMid: "", silent: true)
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

        if hiddenIds.contains(peerId) { setHidden(peerId, false) }

        // The official account is a local inbox: text only, read immediately,
        // never sent over the relay and never answered.
        if contact(peerId)?.official == true {
            guard kind == .text else { return }
            let mid = UUID().uuidString
            messagesByPeer[peerId, default: []].append(
                ChatMessage(
                    id: mid,
                    body: body,
                    mine: true,
                    ts: Date(),
                    kind: .text,
                    replyTo: replyTo,
                    delivery: .read
                )
            )
            if let i = contacts.firstIndex(where: { $0.id == peerId }) {
                contacts[i].lastMessage = body
            }
            objectWillChange.send()
            scheduleSave()
            return
        }

        let mid = UUID().uuidString

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
            case .invite: snippet = "グループへの招待"
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

    /// Expiry timestamp for the peer's disappearing timer (nil = off).
    private func expiry(_ peerId: String) -> Int64? {
        let seconds = ttl(for: peerId)
        guard seconds > 0 else { return nil }
        return Int64(Date().addingTimeInterval(Double(seconds)).timeIntervalSince1970 * 1000)
    }

    /// Seal a payload with libsignal and POST it to the peer's mailbox. Does
    /// nothing (message stays local) without a live Tor relay.
    private func transmit(
        _ payload: Data,
        to peerId: String,
        markMid: String,
        silent: Bool = false,
        voip: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard let peer = contact(peerId),
              let boxText = peer.box,
              let box = try? Base64URL.decode(boxText), box.count == 32,
              let service = relayService(),
              let replyBox = ensureRecvBox(peerId) else {
            completion?()
            return
        }
        Task { [weak self] in
            defer { completion?() }
            var attempt = 0
            while true {
                do {
                    try await service.send(
                        payload: payload, to: peerId, box: box,
                        replyBox: replyBox, silent: silent, voip: voip
                    )
                    self?.markMessage(peerId, mid: markMid, delivery: .delivered)
                    if !markMid.isEmpty { self?.lastSyncError = nil }
                    return
                } catch {
                    attempt += 1
                    if !markMid.isEmpty {
                        self?.lastSyncError = error.localizedDescription
                    }
                    let retry = !markMid.isEmpty && attempt < 3
                    guard retry else {
                        self?.markMessage(peerId, mid: markMid, delivery: .sent)
                        return
                    }
                    try? await Task.sleep(
                        nanoseconds: UInt64(attempt) * 1_000_000_000
                    )
                }
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
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = Self.previewText(of: messagesByPeer[peerId]?.last)
        }
        if everyone, message.mine {
            let payload = DeleteMessage(ids: [message.id])
            if let json = try? payload.toPayloadJSON() {
                transmit(json, to: peerId, markMid: "", silent: true)
            }
        }
        scheduleSave()
    }

    private static func previewText(of message: ChatMessage?) -> String {
        guard let message else { return "" }
        switch message.kind {
        case .text: return message.body
        case .image: return "画像"
        case .file: return "ファイル"
        case .location: return "位置情報"
        case .invite: return "グループへの招待"
        }
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
        guard let service = relayService(), let blob = Self.sealBlob(data) else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let blobId = try await service.putBlob(
                    blob.ciphertext,
                    isolation: "g:" + groupId
                )
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
        guard let service = relayService() else { return }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let original = url.lastPathComponent
        Task { [weak self] in
            guard let self else { return }
            do {
                let blobId = try await service.putBlob(
                    blob.ciphertext,
                    isolation: "g:" + groupId
                )
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
        senderId: String,
        senderName: String,
        remoteId: String?
    ) async {
        guard let service = relayService() else { return }
        guard let blob = try? await service.getBlob(
            id: manifest.id,
            isolation: "g:" + groupId
        ) else { return }
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
                senderId: senderId,
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
        transmit(json, to: peerId, markMid: "", silent: true)
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
        notify: Bool,
        sendReceipt: Bool = true
    ) {
        let isOpen = activePeer == peerId
        if hiddenIds.contains(peerId) {
            setHidden(peerId, false)
        }
        if let i = contacts.firstIndex(where: { $0.id == peerId }) {
            contacts[i].lastMessage = preview
            if !isOpen { contacts[i].unread += 1 }
        }
        updateBadge()
        scheduleSave()
        if isOpen, sendReceipt {
            sendReadReceipts(peerId)
        } else if notify, !isMuted(peerId), UIApplication.shared.applicationState != .active {
            NotificationManager.shared.message(
                from: contact(peerId)?.name ?? "RichMan",
                preview: preview,
                peerId: peerId
            )
        }
    }

    // MARK: data deletion (this device only)

    /// Delete every message on this device, keeping contacts and the official feed.
    func clearAllMessages() {
        // Security-zone action while the app is PIN-locked: operate on the
        // sealed file directly instead of the (intentionally empty) memory.
        if persistenceEnabled, !loaded {
            guard var state = LocalStore.load() else { return }
            let keep = state.contacts.first { $0.official }?.id
            state.messages = state.messages.filter { $0.key == keep }
            state.groupMessages.removeAll()
            for i in state.contacts.indices {
                state.contacts[i].lastMessage = ""
                state.contacts[i].unread = 0
            }
            LocalStore.save(state)
            return
        }
        let keep = contacts.first { $0.official }?.id
        messagesByPeer = messagesByPeer.filter { $0.key == keep }
        groupMessages.removeAll()
        for i in contacts.indices {
            contacts[i].lastMessage = ""
            contacts[i].unread = 0
        }
        for i in groups.indices {
            groups[i].unread = 0
        }
        updateBadge()
        scheduleSave()
    }

    /// Delete contacts and messages on this device. The peer's copy is untouched.
    /// Also used by the emergency passcode while the app is PIN-locked, so it
    /// edits the sealed file when the in-memory state is suspended.
    func clearAllContacts() {
        if persistenceEnabled, !loaded {
            guard var state = LocalStore.load() else { return }
            let keep = state.contacts.first { $0.official }?.id
            state.contacts.removeAll { !$0.official }
            state.messages = state.messages.filter { $0.key == keep }
            state.groups.removeAll()
            state.groupMessages.removeAll()
            state.pendingBoxes.removeAll()
            state.blocked.removeAll()
            LocalStore.save(state)
            return
        }
        let keep = contacts.first { $0.official }?.id
        contacts.removeAll { !$0.official }
        messagesByPeer = messagesByPeer.filter { $0.key == keep }
        groups.removeAll()
        groupMessages.removeAll()
        pendingBoxes.removeAll()
        blockedIds.removeAll()
        UserDefaults.standard.removeObject(forKey: mutedKey)
        UserDefaults.standard.removeObject(forKey: hiddenKey)
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
        stopEventChannel()
        contacts.removeAll()
        groups.removeAll()
        messagesByPeer.removeAll()
        groupMessages.removeAll()
        blockedIds.removeAll()
        mutedIds.removeAll()
        hiddenIds.removeAll()
        typingPeers.removeAll()
        typingClearTasks.values.forEach { $0.cancel() }
        typingClearTasks.removeAll()
        lastTypingSent.removeAll()
        pendingBoxes.removeAll()
        saveTask?.cancel()
        lastRegisteredBoxes = []
        pushRegistered = false
        inviteGeneration += 1
        warmInviteRaw = nil
        warmInviteAt = nil
        prewarmingInvite = false
        UserDefaults.standard.removeObject(forKey: blockedKey)
        UserDefaults.standard.removeObject(forKey: mutedKey)
        UserDefaults.standard.removeObject(forKey: hiddenKey)
        LocalStore.wipe()
        MediaStore.clearAll()
        crypto.wipeLocalState()
    }

    /// Start over with a brand-new identity in the same process. Used by the
    /// emergency passcode (random name + straight into the app) and by
    /// Settings → アカウントを消去 (empty name + onboarding). The old provider is
    /// discarded, so nothing from the previous account survives in memory.
    func recreateAccount(displayName newName: String) {
        // Remove this device token from every old mailbox before the identity
        // (and its receive boxes) is destroyed, otherwise old chats keep
        // pushing notifications to the new account.
        unregisterPush()
        pollTask?.cancel()
        pollTask = nil
        relayServiceInstance = nil
        relayTransport = nil
        relayFactory = nil
        activePeer = nil
        activeGroup = nil
        fastPeer = nil

        wipeAllLocal()
        crypto = CryptoProviderFactory.make()

        displayName = newName
        blockedIds = []
        mutedIds = []
        hiddenIds = []
        loaded = true
        seedOfficialIfNeeded()
        scheduleSave()
    }

    // MARK: official account (one-way broadcast, local only)

    private static let officialWelcome = """
    RichMan へようこそ。

    ・メッセージ・画像・ファイル・通話は端末間で暗号化されます。
    ・このアカウントは運営からのお知らせ用です。
    """

    private func seedOfficialIfNeeded() {
        if !contacts.contains(where: { $0.official }) {
            let official = Contact(id: "official", name: "Richman", official: true)
            contacts.insert(official, at: 0)
            if let index = contacts.firstIndex(where: { $0.official }) {
                contacts[index].lastMessage = "ようこそ RichMan へ"
            }
        }

        // Keep the welcome text current on existing installs (the old copy
        // claimed location sharing that the app does not perform).
        let welcome = Self.officialWelcome
        if var list = messagesByPeer["official"],
           let index = list.firstIndex(where: { $0.id == "official-welcome" }) {
            if list[index].body != welcome {
                list[index].body = welcome
                messagesByPeer["official"] = list
            }
        } else if contacts.contains(where: { $0.official }) {
            messagesByPeer["official", default: []].append(
                ChatMessage(
                    id: "official-welcome",
                    body: welcome,
                    mine: false,
                    ts: Date().addingTimeInterval(-3600)
                )
            )
        }
    }

    // MARK: disappearing messages

    func ttl(for peerId: String) -> Int {
        UserDefaults.standard.integer(forKey: "rm.ttl.\(peerId)")
    }

    func setTTL(_ seconds: Int, for peerId: String) {
        guard ttl(for: peerId) != seconds else { return }
        UserDefaults.standard.set(seconds, forKey: "rm.ttl.\(peerId)")
        purgeExpired(peerId)
        appendSystem(peerId, text: ttlSystemLabel(seconds))
        scheduleSave()
        // Keep both ends' expiry in step (Android sends `{"t":"ttl","ms":N}`).
        if let json = try? TtlMessage(ms: Int64(seconds) * 1000).toPayloadJSON() {
            transmit(json, to: peerId, markMid: "", silent: true)
        }
    }

    private func appendSystem(_ peerId: String, text: String) {
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: UUID().uuidString,
                body: text,
                mine: false,
                ts: Date(),
                system: true
            )
        )
        scheduleSave()
    }

    /// Local call history row shown in the chat after a call ends.
    func appendCallRecord(
        peerId: String,
        seconds: Int,
        outgoing: Bool,
        missed: Bool
    ) {
        guard contact(peerId) != nil else { return }
        let body: String
        if missed {
            body = outgoing ? "発信（応答なし）" : "不在着信"
        } else {
            let minutes = seconds / 60
            let secs = seconds % 60
            body = "通話（\(outgoing ? "発信" : "着信")） \(minutes):\(String(format: "%02d", secs))"
        }
        messagesByPeer[peerId, default: []].append(
            ChatMessage(
                id: UUID().uuidString,
                body: body,
                mine: false,
                ts: Date(),
                system: true
            )
        )
        // The app may be suspended right after a background CallKit call ends;
        // persist the call record immediately instead of debouncing.
        persistNow()
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
            if let i = contacts.firstIndex(where: { $0.id == peerId }) {
                contacts[i].lastMessage = Self.previewText(of: kept.last)
            }
            scheduleSave()
        }
    }

    /// Per-conversation disappearing timer for a group (local to this device).
    func setGroupTTL(_ seconds: Int, for groupId: String) {
        UserDefaults.standard.set(seconds, forKey: "rm.ttl.\(groupId)")
        purgeExpiredGroup(groupId)
    }

    /// Apply every conversation's timer (used when the Talks list appears).
    func purgeAllExpired() {
        for peerId in Array(messagesByPeer.keys) {
            purgeExpired(peerId)
        }
        for groupId in Array(groupMessages.keys) {
            purgeExpiredGroup(groupId)
        }
    }

    func purgeExpiredGroup(_ groupId: String) {
        let seconds = ttl(for: groupId)
        guard seconds > 0, let list = groupMessages[groupId] else { return }
        let cutoff = Date().addingTimeInterval(-Double(seconds))
        let kept = list.filter { $0.ts > cutoff }
        if kept.count != list.count {
            groupMessages[groupId] = kept
            scheduleSave()
        }
    }

    /// Global retention (Settings → データ). 0 keeps messages forever.
    func purgeOldMessages(days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        messagesByPeer = messagesByPeer.mapValues { $0.filter { $0.ts > cutoff } }
        groupMessages = groupMessages.mapValues { $0.filter { $0.ts > cutoff } }
        for i in contacts.indices {
            contacts[i].lastMessage = Self.previewText(of: messagesByPeer[contacts[i].id]?.last)
        }
        scheduleSave()
    }

    // MARK: media

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

        guard let service = relayService(), let blob = Self.sealBlob(data) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let blobId = try await service.putBlob(
                    blob.ciphertext,
                    isolation: "p:" + peerId
                )
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

        guard let service = relayService(), let blob = Self.sealBlob(saved.data) else {
            return
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let original = url.lastPathComponent
        Task { [weak self] in
            guard let self else { return }
            do {
                let blobId = try await service.putBlob(
                    blob.ciphertext,
                    isolation: "p:" + peerId
                )
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
        guard let service = relayService() else { return }
        guard let blob = try? await service.getBlob(
            id: id,
            isolation: "p:" + peerId
        ) else {
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

    /// True when a 1:1 chat holds an invitation card (pending or answered) for
    /// this group id, so group traffic must not auto-create the group.
    private func hasInviteCard(for gid: String) -> Bool {
        messagesByPeer.values.contains { list in
            list.contains { $0.kind == .invite && $0.inviteGid == gid }
        }
    }

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

    // MARK: group invitations

    /// Join a group after the user taps 参加 on an invite card.
    @discardableResult
    func acceptGroupInvite(_ message: ChatMessage, in peerId: String) -> ChatGroup? {
        guard let gid = message.inviteGid else { return nil }
        let hub = message.inviteHub ?? peerId
        ensureGroup(
            gid,
            name: message.inviteName ?? message.body,
            members: (message.inviteMembers ?? []) + [hub]
        )
        if let index = groups.firstIndex(where: { $0.id == gid }) {
            groups[index].ownerId = hub
        }
        setInviteState(message.id, in: peerId, accepted: true)
        return group(gid)
    }

    /// Decline an invite: the hub removes us so no group is created locally.
    func declineGroupInvite(_ message: ChatMessage, in peerId: String) {
        guard let gid = message.inviteGid else { return }
        setInviteState(message.id, in: peerId, accepted: false)
        let hub = message.inviteHub ?? peerId
        let payload = GroupMembershipMessage(
            t: MessageType.groupLeave.rawValue,
            gid: gid,
            id: crypto.myId,
            name: displayName,
            n: displayName,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        if let json = try? payload.toPayloadJSON() {
            transmit(json, to: hub, markMid: "")
        }
    }

    private func setInviteState(_ messageId: String, in peerId: String, accepted: Bool) {
        guard var list = messagesByPeer[peerId],
              let index = list.firstIndex(where: { $0.id == messageId }) else { return }
        list[index].inviteAccepted = accepted
        messagesByPeer[peerId] = list
        scheduleSave()
    }

    func send(toGroup id: String, text: String, replyTo: ChatMessage? = nil) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let group = self.group(id) else { return }
        if hiddenIds.contains(id) { setHidden(id, false) }
        let mid = UUID().uuidString
        let mentioned = mentionedIds(in: body, group: group)

        var replyWireId: String?
        var replyName: String?
        var replyPreview: String?
        if let replyTo {
            replyWireId = replyTo.remoteId ?? replyTo.id
            replyName = replyTo.mine
                ? displayName
                : (replyTo.senderName ?? "メンバー")
            let snippet: String
            switch replyTo.kind {
            case .image: snippet = "画像"
            case .file: snippet = "ファイル"
            case .location: snippet = "位置情報"
            case .invite: snippet = "グループへの招待"
            case .text: snippet = replyTo.body
            }
            replyPreview = String(snippet.prefix(80))
        }

        groupMessages[id, default: []].append(
            ChatMessage(
                id: mid,
                body: body,
                mine: true,
                ts: Date(),
                replyTo: replyTo?.id,
                remoteId: mid,
                replyName: replyName,
                replyText: replyPreview,
                mentions: mentioned.isEmpty ? nil : mentioned
            )
        )
        scheduleSave()

        let message = GroupMessage(
            gid: id,
            kind: "text",
            b: body,
            n: displayName,
            sender: crypto.myId,
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            mid: mid,
            re: replyWireId,
            ren: replyName,
            ret: replyPreview,
            mentions: mentioned.isEmpty ? nil : mentioned
        )
        guard let json = try? message.toPayloadJSON() else { return }
        for member in group.memberIds where member != crypto.myId {
            transmit(json, to: member, markMid: "")
        }
    }

    /// Resolve typed `@name` text to member ids. Selection in the composer
    /// inserts the same text, so one path handles both.
    func mentionedIds(in text: String, group: ChatGroup) -> [String] {
        // "@全員" / "@all" pings every other member, matching the Android client.
        if text.contains("@全員") ||
            text.range(of: "@all", options: .caseInsensitive) != nil {
            return group.memberIds.filter { $0 != crypto.myId }
        }
        return group.memberIds.filter { id in
            guard id != crypto.myId,
                  let name = contact(id)?.name,
                  !name.isEmpty else { return false }
            return text.contains("@\(name)")
        }
    }

    func receive(inGroup id: String, from sender: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if hiddenIds.contains(id) { setHidden(id, false) }
        groupMessages[id, default: []].append(
            ChatMessage(
                id: UUID().uuidString, body: body, mine: false, ts: Date(), senderName: sender
            )
        )
        scheduleSave()
    }

    /// Creator: tell the members and remove it everywhere.
    func deleteGroup(_ id: String) {
        guard let group = group(id), group.ownerId == crypto.myId else { return }
        // Android dissolves a group with group_remove(id = hub). Sending an
        // empty group_del only deletes messages on Android.
        let payload = GroupMembershipMessage(
            t: MessageType.groupRemove.rawValue,
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

    private func removeGroupLocally(_ id: String) {
        groups.removeAll { $0.id == id }
        groupMessages.removeValue(forKey: id)
        scheduleSave()
    }

    func addMembers(_ ids: [String], to groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }),
              groups[index].ownerId == crypto.myId else { return }
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
        guard let index = groups.firstIndex(where: { $0.id == groupId }),
              groups[index].ownerId == crypto.myId else { return }
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

    private func handleMembership(
        _ membership: GroupMembershipMessage,
        actor: String
    ) {
        guard let index = groups.firstIndex(where: { $0.id == membership.gid }) else {
            return
        }
        let group = groups[index]
        let isOwner = group.ownerId == actor
        let isMember = group.memberIds.contains(actor)
        switch membership.t {
        case MessageType.groupAdd.rawValue:
            guard isOwner else { return }
            if let id = membership.id, id != crypto.myId,
               !group.memberIds.contains(id) {
                groups[index].memberIds.append(id)
            }
        case MessageType.groupRemove.rawValue:
            // Android and iOS both require the owner/hub to remove or dissolve.
            guard isOwner, let id = membership.id else { return }
            if id == crypto.myId || id == group.ownerId {
                removeGroupLocally(group.id)
                return
            }
            groups[index].memberIds.removeAll { $0 == id }
        case MessageType.groupLeave.rawValue:
            // Android's non-hub members omit `id`; the authenticated sender is
            // the leaver. Only the leaver can remove themselves.
            let leaver = membership.id ?? actor
            guard leaver == actor, isMember || isOwner else { return }
            if leaver == group.ownerId {
                removeGroupLocally(group.id)
                return
            }
            groups[index].memberIds.removeAll { $0 == leaver }
            // If we are the hub, fan out the removal so Android members (which
            // ignore a non-hub group_leave) also drop the member.
            if isOwner {
                let remove = GroupMembershipMessage(
                    t: MessageType.groupRemove.rawValue,
                    gid: group.id,
                    id: leaver,
                    name: membership.name,
                    n: displayName,
                    ts: Int64(Date().timeIntervalSince1970 * 1000)
                )
                if let json = try? remove.toPayloadJSON() {
                    for member in groups[index].memberIds
                    where member != crypto.myId && member != leaver {
                        transmit(json, to: member, markMid: "")
                    }
                }
            }
        default:
            break
        }
        scheduleSave()
    }

    private func appendGroupMessage(_ groupId: String, message: ChatMessage) {
        if !message.mine, hiddenIds.contains(groupId) {
            setHidden(groupId, false)
        }
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
            case .invite: preview = "グループへの招待"
            case .text: preview = message.body
            }
            let mentioned = message.mentions?.contains(crypto.myId) == true
            if !isMuted(groupId) {
                NotificationManager.shared.message(
                    from: message.senderName ?? group(groupId)?.name ?? "グループ",
                    preview: mentioned ? "あなた宛て: \(preview)" : preview
                )
            }
        }
    }

    /// Leave a group (members) — the creator dissolves it for everyone instead.
    func leaveGroup(_ id: String) {
        guard let group = group(id) else { return }
        let isOwner = group.ownerId == crypto.myId
        // Android hubs dissolve with group_remove(id = hub); members send
        // group_leave to the hub. Send to the owner too (it is not in memberIds).
        let payload = GroupMembershipMessage(
            t: isOwner ? MessageType.groupRemove.rawValue
                       : MessageType.groupLeave.rawValue,
            gid: id,
            id: crypto.myId,
            name: displayName,
            n: displayName,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        if let json = try? payload.toPayloadJSON() {
            var recipients = Set(group.memberIds)
            if let owner = group.ownerId { recipients.insert(owner) }
            recipients.remove(crypto.myId)
            for member in recipients {
                transmit(json, to: member, markMid: "")
            }
        }
        removeGroupLocally(id)
    }

    /// Remove the group and its history from this device only (no signals).
    func deleteGroupLocally(_ id: String) {
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
        scheduleSave()
        registerPushIfNeeded()
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

    /// Mint one invite ahead of time so the QR appears instantly when
    /// 友だちを追加 opens. Each displayed QR is single-use; a fresh replacement
    /// is minted in the background for the next display.
    func prewarmInvite(using transport: RelayTransport?) {
        guard let transport,
              !prewarmingInvite,
              warmInviteRaw == nil else { return }
        prewarmingInvite = true
        let generation = inviteGeneration
        Task { [weak self] in
            guard let self else { return }
            var raw: String?
            for attempt in 0..<4 {
                raw = try? await self.makeRelayInvite(using: transport)
                if raw != nil { break }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            self.prewarmingInvite = false
            if let raw,
               self.inviteGeneration == generation,
               self.warmInviteRaw == nil {
                self.warmInviteRaw = raw
                self.warmInviteAt = Date()
            }
        }
    }

    /// Hand out the pre-minted invite once, if it is still inside the relay's
    /// 15-minute window, and start minting the next one.
    func takeWarmInvite(using transport: RelayTransport?) -> String? {
        guard let raw = warmInviteRaw, let at = warmInviteAt,
              Date().timeIntervalSince(at) < 10 * 60 else {
            warmInviteRaw = nil
            warmInviteAt = nil
            return nil
        }
        warmInviteRaw = nil
        warmInviteAt = nil
        prewarmInvite(using: transport)
        return raw
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
        // Announce ourselves immediately so the inviter's app creates the
        // contact without waiting for the first chat message.
        if let profile = try? ProfileMessage(n: displayName, av: 0).toPayloadJSON() {
            transmit(profile, to: c.id, markMid: "", silent: true)
        }
        registerPushIfNeeded()
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

struct ChatMessage: Identifiable, Hashable, Codable {
    enum Kind: String, Hashable, Codable {
        case text, image, file, location, invite
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
    /// Authenticated sender id for group messages (from the libsignal session,
    /// not the self-declared JSON field).
    var senderId: String? = nil
    /// The sender's wire message id, kept for delete-for-everyone receipts.
    var remoteId: String? = nil
    /// Inbound reply target metadata (survives even if the referenced message
    /// was already deleted locally).
    var replyName: String? = nil
    var replyText: String? = nil
    /// Group mention recipients (member ids).
    var mentions: [String]? = nil
    /// Local media file name (image/file messages).
    var mediaName: String? = nil
    var fileSize: Int? = nil
    /// Pending group invitation (kind == .invite). Nil on accepted/declined
    /// cards? No: `inviteAccepted` carries the decision, the rest stay filled
    /// so the card can still name the group after the fact.
    var inviteGid: String? = nil
    var inviteName: String? = nil
    var inviteHub: String? = nil
    var inviteMembers: [String]? = nil
    /// nil = awaiting the user, true = joined, false = declined.
    var inviteAccepted: Bool? = nil
    /// Local system notice (e.g. a disappearing-message change) rendered
    /// centred like a date divider instead of as a chat bubble.
    var system: Bool? = nil
}
