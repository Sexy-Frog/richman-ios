import SwiftUI
import UIKit

// MARK: トーク

struct TalksView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var path = NavigationPath()
    @State private var showCreateGroup = false
    @State private var peek: Contact?

    private var visibleGroups: [ChatGroup] {
        store.groups.filter { !store.isHidden($0.id) }
    }

    private var visibleContacts: [Contact] {
        store.contacts.filter { !store.isHidden($0.id) }
    }

    private var sortedTalks: [TalkItem] {
        var items: [TalkItem] = []
        for group in visibleGroups {
            items.append(
                TalkItem(
                    id: "g:" + group.id,
                    date: store.messages(forGroup: group.id).last?.ts ?? .distantPast,
                    kind: .group(group)
                )
            )
        }
        for contact in visibleContacts {
            items.append(
                TalkItem(
                    id: "c:" + contact.id,
                    date: store.messages(for: contact.id).last?.ts ?? .distantPast,
                    kind: .contact(contact)
                )
            )
        }
        return items.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if visibleContacts.isEmpty && visibleGroups.isEmpty
                    && store.pendingGroupInvites.isEmpty {
                    EmptyState(
                        icon: "bubble.left.and.bubble.right",
                        title: "まだトークがありません",
                        message: "「友だち」から相手を追加すると、ここにトークが表示されます。"
                    )
                } else {
                    List {
                        if !store.pendingGroupInvites.isEmpty {
                            Section("グループへの招待") {
                                ForEach(store.pendingGroupInvites) { invite in
                                    inviteRow(invite)
                                }
                            }
                        }
                        if !sortedTalks.isEmpty {
                            Section("トーク") {
                                ForEach(sortedTalks) { item in
                                    talkRow(item)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .contentMargins(.bottom, 88, for: .scrollContent)
                    .navigationDestination(for: Contact.self) { ChatView(contact: $0) }
                    .navigationDestination(for: ChatGroup.self) { GroupChatView(group: $0) }
                }
            }
            .navigationTitle("トーク")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottomTrailing) {
                FABButton(label: "グループを作成") { showCreateGroup = true }
            }
            .sheet(isPresented: $showCreateGroup) {
                CreateGroupView().environmentObject(store)
            }
            .onAppear {
                store.purgeAllExpired()
                #if DEBUG
                if peek == nil,
                   let id = UserDefaults.standard.string(forKey: "rm.peek"),
                   let contact = store.contact(id) {
                    peek = contact
                }
                #endif
            }
        }
        .overlay {
            if let contact = peek {
                ChatPeekPopup(
                    contact: contact,
                    onOpen: {
                        peek = nil
                        path.append(contact)
                    },
                    onClose: { peek = nil }
                )
            }
        }
    }

    @ViewBuilder
    private func talkRow(_ item: TalkItem) -> some View {
        switch item.kind {
        case .group(let group):
            GroupRow(group: group)
                .contentShape(Rectangle())
                .onTapGesture { path.append(group) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        store.setHidden(group.id, true)
                    } label: {
                        Label("非表示", systemImage: "eye.slash")
                    }
                    .tint(.gray)

                    Button(role: .destructive) {
                        if group.ownerId == store.myId {
                            store.deleteGroup(group.id)
                        } else {
                            store.leaveGroup(group.id)
                        }
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
        case .contact(let contact):
            ContactRow(
                contact: contact,
                typing: store.isTyping(contact.id)
            )
            .contentShape(Rectangle())
            .onTapGesture { path.append(contact) }
            .onLongPressGesture(minimumDuration: 0.45) {
                peek = contact
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !contact.official {
                    Button {
                        store.setHidden(contact.id, true)
                    } label: {
                        Label("非表示", systemImage: "eye.slash")
                    }
                    .tint(.gray)

                    Button(role: .destructive) {
                        store.clearChat(contact.id)
                        store.setHidden(contact.id, true)
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func inviteRow(_ invite: PendingGroupInvite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RM.primary, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.message.inviteName ?? "グループ")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text("\(store.contact(invite.peerId)?.name ?? "友だち") からの招待")
                        .font(.caption)
                        .foregroundStyle(RM.onSurfaceVariant)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button("参加") {
                    if let group = store.acceptGroupInvite(
                        invite.message, in: invite.peerId
                    ) {
                        path.append(group)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(RM.primary)
                .controlSize(.small)

                Button("拒否") {
                    store.declineGroupInvite(
                        invite.message, in: invite.peerId
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TalkItem: Identifiable {
    enum Kind {
        case group(ChatGroup)
        case contact(Contact)
    }

    let id: String
    let date: Date
    let kind: Kind
}

/// LINE-style long-press popup for a talk: recent messages plus quick actions.
/// Rendered in place (never presented as a bottom sheet).
private struct ChatPeekPopup: View {
    let contact: Contact
    var onOpen: () -> Void
    var onClose: () -> Void
    @EnvironmentObject private var store: ChatStore

    private var recent: [ChatMessage] {
        Array(
            store.messages(for: contact.id)
                .filter { $0.system != true }
                .suffix(6)
        )
    }
    private var muted: Bool { store.isMuted(contact.id) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                header
                if !recent.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(recent) { message in
                                HStack(alignment: .top, spacing: 8) {
                                    if message.mine { Spacer(minLength: 30) }
                                    Text(previewText(message))
                                        .font(.system(size: 13))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .foregroundStyle(RM.onSurface)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(
                                            message.mine
                                                ? RM.primary.opacity(0.16)
                                                : RM.surfaceVariant,
                                            in: RoundedRectangle(cornerRadius: 10)
                                        )
                                    if !message.mine { Spacer(minLength: 30) }
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 280)
                }
                Divider()
                actionRow("開く", "bubble.left", tint: RM.primary) { onOpen() }
                actionRow(
                    muted ? "通知をオン" : "通知オフ",
                    muted ? "bell" : "bell.slash"
                ) {
                    store.setMuted(contact.id, !muted)
                    onClose()
                }
                actionRow("既読にする", "envelope.open") {
                    store.markRead(contact.id)
                    onClose()
                }
                if !contact.official {
                    actionRow("非表示", "eye.slash") {
                        store.setHidden(contact.id, true)
                        onClose()
                    }
                    actionRow("削除", "trash", tint: RM.error) {
                        store.clearChat(contact.id)
                        store.setHidden(contact.id, true)
                        onClose()
                    }
                }
            }
            .frame(maxWidth: 352)
            .background(RM.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Avatar(contact: contact, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.headline)
                    .lineLimit(1)
                if contact.unread > 0 {
                    Text("未読 \(contact.unread)件")
                        .font(.caption2)
                        .foregroundStyle(RM.primary)
                } else {
                    Text("トークのプレビュー")
                        .font(.caption2)
                        .foregroundStyle(RM.onSurfaceVariant)
                }
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(RM.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("閉じる")
        }
        .padding(14)
    }

    private func actionRow(
        _ title: String,
        _ icon: String,
        tint: Color = RM.onSurface,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 22)
                Text(title)
                    .font(.subheadline)
                Spacer()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func previewText(_ message: ChatMessage) -> String {
        switch message.kind {
        case .image: return "画像"
        case .file: return "ファイル"
        case .location: return "位置情報"
        case .invite: return "グループへの招待"
        case .text: return message.body
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    var typing: Bool = false
    var body: some View {
        HStack(spacing: 12) {
            if contact.official {
                Image(systemName: "megaphone.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Brand.signalBlue, in: Circle())
            } else {
                Avatar(contact: contact)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(contact.name).font(.body.weight(.semibold))
                    if contact.official {
                        Text("公式")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(RM.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RM.primary.opacity(0.12), in: Capsule())
                    }
                }
                if typing {
                    Text("入力中…")
                        .font(.subheadline)
                        .foregroundStyle(RM.primary)
                } else {
                    Text(contact.lastMessage.isEmpty ? "トークを始めましょう" : contact.lastMessage)
                        .font(.subheadline).foregroundStyle(RM.onSurfaceVariant).lineLimit(1)
                }
            }
            Spacer()
            if contact.unread > 0 {
                Text("\(contact.unread)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .frame(minWidth: 20)
                    .background(RM.primary, in: Capsule())
                    .accessibilityLabel("未読 \(contact.unread)件")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: 友だち

struct FriendsView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var tor: TorSession
    @State private var showAdd = false
    @State private var reportTarget: Contact?

    private var friends: [Contact] { store.contacts.filter { !$0.official } }

    var body: some View {
        NavigationStack {
            Group {
                if friends.isEmpty {
                    EmptyState(
                        icon: "person.2",
                        title: "友だちがいません",
                        message: "QRコード（招待コード）を見せ合って友だちを追加します。"
                    )
                } else {
                    List {
                        ForEach(friends) { friend in
                            NavigationLink(value: friend) {
                                FriendRow(contact: friend, blocked: store.isBlocked(friend.id))
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    store.removeContact(friend.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                                Button {
                                    store.setBlocked(friend.id, !store.isBlocked(friend.id))
                                } label: {
                                    Label(
                                        store.isBlocked(friend.id) ? "解除" : "ブロック",
                                        systemImage: "hand.raised"
                                    )
                                }
                                .tint(.orange)
                                Button {
                                    reportTarget = friend
                                } label: {
                                    Label("通報", systemImage: "flag")
                                }
                                .tint(.red)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .contentMargins(.bottom, 88, for: .scrollContent)
                    .navigationDestination(for: Contact.self) { ChatView(contact: $0) }
                }
            }
            .navigationTitle("友だち")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Have the QR ready by the time 友だちを追加 is tapped.
                store.prewarmInvite(using: tor.readyTransport)
            }
            .overlay(alignment: .bottomTrailing) {
                FABButton(label: "友だちを追加") { showAdd = true }
            }
            .sheet(isPresented: $showAdd) {
                AddFriendView()
                    .environmentObject(store)
                    .environmentObject(tor)
            }
            .sheet(item: $reportTarget) { ReportSheet(contact: $0).environmentObject(store) }
        }
    }
}

private struct FriendRow: View {
    let contact: Contact
    let blocked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Avatar(contact: contact)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(contact.name).font(.body.weight(.semibold))
                    if blocked {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(contact.lastMessage.isEmpty ? "トークを始めましょう" : contact.lastMessage)
                    .font(.subheadline)
                    .foregroundStyle(RM.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer()
            if contact.unread > 0 {
                Text("\(contact.unread)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(RM.primary, in: Circle())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: shared bits

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44)).foregroundStyle(RM.onSurfaceVariant)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline).foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RM.background)
    }
}

struct FABButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(RM.primary, in: Circle())
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
    }
}

struct Avatar: View {
    let name: String
    var image: UIImage? = nil
    var size: CGFloat = 40

    init(name: String, image: UIImage? = nil, size: CGFloat = 40) {
        self.name = name
        self.image = image
        self.size = size
    }

    init(contact: Contact, size: CGFloat = 40) {
        self.name = contact.name
        self.image = contact.avatarFile.flatMap { MediaStore.image(named: $0) }
        self.size = size
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.signalBlue)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(RM.outline, lineWidth: image == nil ? 0 : 1))
    }
}
