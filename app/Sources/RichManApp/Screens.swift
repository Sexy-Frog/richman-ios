import SwiftUI

// MARK: トーク

struct TalksView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var showCreateGroup = false

    var body: some View {
        NavigationStack {
            Group {
                if store.contacts.isEmpty && store.groups.isEmpty {
                    EmptyState(
                        icon: "bubble.left.and.bubble.right",
                        title: "まだトークがありません",
                        message: "「友だち」から相手を追加すると、ここにトークが表示されます。"
                    )
                } else {
                    List {
                        if !store.groups.isEmpty {
                            Section("グループ") {
                                ForEach(store.groups) { group in
                                    NavigationLink(value: group) { GroupRow(group: group) }
                                }
                            }
                        }
                        if !store.contacts.isEmpty {
                            Section("友だち") {
                                ForEach(store.contacts) { contact in
                                    NavigationLink(value: contact) {
                                        ContactRow(contact: contact)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .navigationDestination(for: Contact.self) { ChatView(contact: $0) }
                    .navigationDestination(for: ChatGroup.self) { GroupChatView(group: $0) }
                }
            }
            .navigationTitle("トーク")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("グループを作成", systemImage: "person.3") {
                            showCreateGroup = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateGroup) {
                CreateGroupView().environmentObject(store)
            }
        }
    }
}

private struct ContactRow: View {
    let contact: Contact
    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: contact.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name).font(.body.weight(.semibold))
                Text(contact.lastMessage.isEmpty ? "トークを始めましょう" : contact.lastMessage)
                    .font(.subheadline).foregroundStyle(RM.onSurfaceVariant).lineLimit(1)
            }
            Spacer()
            if contact.unread > 0 {
                Text("\(contact.unread)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(6).background(RM.primary, in: Circle())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: 友だち

struct FriendsView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var showAdd = false
    @State private var reportTarget: Contact?

    var body: some View {
        NavigationStack {
            Group {
                if store.contacts.isEmpty {
                    EmptyState(
                        icon: "person.2",
                        title: "友だちがいません",
                        message: "QRコード（招待コード）を見せ合って友だちを追加します。"
                    )
                } else {
                    List {
                        ForEach(store.contacts) { friend in
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
                    .navigationDestination(for: Contact.self) { ChatView(contact: $0) }
                }
            }
            .navigationTitle("友だち")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddFriendView().environmentObject(store) }
            .sheet(item: $reportTarget) { ReportSheet(contact: $0).environmentObject(store) }
        }
    }
}

private struct FriendRow: View {
    let contact: Contact
    let blocked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: contact.name)
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

struct Avatar: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1)))
            .font(.headline).foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Brand.signalBlue, in: Circle())
    }
}
