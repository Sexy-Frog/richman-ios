import SwiftUI

// MARK: トーク

struct TalksView: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        NavigationStack {
            Group {
                if store.contacts.isEmpty {
                    EmptyState(
                        icon: "bubble.left.and.bubble.right",
                        title: "まだトークがありません",
                        message: "「友だち」から相手を追加すると、ここにトークが表示されます。"
                    )
                } else {
                    List(store.contacts) { c in
                        NavigationLink(value: c) { ContactRow(contact: c) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("トーク")
            .navigationDestination(for: Contact.self) { ChatView(contact: $0) }
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
                    List(store.contacts) { f in
                        HStack(spacing: 12) { Avatar(name: f.name); Text(f.name) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("友だち")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddFriendView().environmentObject(store) }
        }
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
