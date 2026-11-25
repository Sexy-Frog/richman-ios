import SwiftUI

// MARK: トーク

struct TalksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var conversations: [Conversation] = []

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    EmptyState(
                        icon: "bubble.left.and.bubble.right",
                        title: "まだトークがありません",
                        message: "「友だち」から相手を追加すると、ここにトークが表示されます。"
                    )
                } else {
                    List(conversations) { c in
                        NavigationLink(value: c) { ConversationRow(conversation: c) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("トーク")
            .navigationDestination(for: Conversation.self) { c in
                ChatView(conversation: c)
            }
        }
    }
}

struct Conversation: Identifiable, Hashable {
    let id: String          // peer id
    var name: String
    var lastMessage: String
    var unread: Int
}

private struct ConversationRow: View {
    let conversation: Conversation
    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: conversation.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.name).font(.body.weight(.semibold))
                Text(conversation.lastMessage)
                    .font(.subheadline).foregroundStyle(RM.onSurfaceVariant).lineLimit(1)
            }
            Spacer()
            if conversation.unread > 0 {
                Text("\(conversation.unread)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(6).background(RM.primary, in: Circle())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: 友だち

struct FriendsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var friends: [Conversation] = []
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if friends.isEmpty {
                    EmptyState(
                        icon: "person.2",
                        title: "友だちがいません",
                        message: "QRコードを見せ合って友だちを追加します。"
                    )
                } else {
                    List(friends) { f in
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
            .sheet(isPresented: $showAdd) { AddFriendView().environmentObject(model) }
        }
    }
}

// MARK: 設定

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("プロフィール") {
                    LabeledContent("表示名", value: model.displayName)
                    LabeledContent("ID", value: model.crypto.myId).font(.footnote)
                }
                Section("セキュリティ") {
                    NavigationLink("パスコード") { PlaceholderDetail(title: "パスコード") }
                    NavigationLink("自動ロック") { PlaceholderDetail(title: "自動ロック") }
                    NavigationLink("セキュリティゾーン") { PlaceholderDetail(title: "セキュリティゾーン") }
                }
                Section("データ") {
                    NavigationLink("トークを全部消す") { PlaceholderDetail(title: "トークを全部消す") }
                    NavigationLink("友だちを全員消す") { PlaceholderDetail(title: "友だちを全員消す") }
                }
                Section("このアプリ") {
                    LabeledContent("バージョン", value: "0.1.0 (開発中)")
                }
            }
            .navigationTitle("設定")
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

private struct PlaceholderDetail: View {
    let title: String
    var body: some View {
        EmptyState(icon: "hammer", title: title, message: "この画面は移植中です。")
            .navigationTitle(title)
    }
}
