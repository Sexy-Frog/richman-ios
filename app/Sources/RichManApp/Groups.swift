import SwiftUI

// MARK: - Talks row

struct GroupRow: View {
    let group: ChatGroup

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Brand.signalBlue, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.body.weight(.semibold))
                Text("\(group.memberIds.count + 1)人のグループ")
                    .font(.subheadline)
                    .foregroundStyle(RM.onSurfaceVariant)
            }
            Spacer()
            if group.unread > 0 {
                Text("\(group.unread)")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(6).background(RM.primary, in: Circle())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Create

struct CreateGroupView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected: Set<String> = []

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !trimmed.isEmpty && !selected.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("グループ名") {
                    TextField("例: 週末の予定", text: $name)
                }
                Section {
                    if store.contacts.isEmpty {
                        Text("先に友だちを追加してください。")
                            .foregroundStyle(RM.onSurfaceVariant)
                    } else {
                        ForEach(store.contacts) { contact in
                            Button { toggle(contact.id) } label: {
                                HStack(spacing: 12) {
                                    Avatar(name: contact.name)
                                    Text(contact.name).foregroundStyle(RM.onSurface)
                                    Spacer()
                                    Image(
                                        systemName: selected.contains(contact.id)
                                            ? "checkmark.circle.fill" : "circle"
                                    )
                                    .foregroundStyle(
                                        selected.contains(contact.id)
                                            ? RM.primary : RM.onSurfaceVariant
                                    )
                                }
                            }
                        }
                    }
                } header: {
                    Text("メンバー")
                } footer: {
                    Text("作成者を含めて \(selected.count + 1) 人で始まります。")
                }
            }
            .navigationTitle("グループを作成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") {
                        store.createGroup(name: trimmed, memberIds: Array(selected))
                        dismiss()
                    }
                    .disabled(!canCreate)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}

// MARK: - Chat

struct GroupChatView: View {
    let group: ChatGroup
    @EnvironmentObject private var store: ChatStore
    @State private var draft = ""
    @State private var showInfo = false

    private var messages: [ChatMessage] { store.messages(forGroup: group.id) }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            GroupBubble(message: message) { target in
                                store.deleteGroupMessage(target, in: group.id)
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            composer
        }
        .background(RM.chatBg)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
            }
        }
        .sheet(isPresented: $showInfo) {
            GroupInfoView(groupId: group.id).environmentObject(store)
        }
        .onAppear { store.setActiveGroup(group.id) }
        .onDisappear { store.setActiveGroup(nil) }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("メッセージ", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RM.surface, in: Capsule())
                .overlay(Capsule().stroke(RM.outline, lineWidth: 1))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? RM.primary : RM.onSurfaceVariant)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RM.background)
    }

    private func send() {
        let text = draft
        draft = ""
        store.send(toGroup: group.id, text: text)
    }
}

private struct GroupBubble: View {
    let message: ChatMessage
    let onDelete: (ChatMessage) -> Void

    var body: some View {
        HStack(alignment: .bottom) {
            if message.mine { Spacer(minLength: 48) }
            VStack(alignment: message.mine ? .trailing : .leading, spacing: 3) {
                if !message.mine, let sender = message.senderName {
                    Text(sender)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(RM.onSurfaceVariant)
                        .padding(.leading, 6)
                }
                Text(message.body)
                    .foregroundStyle(message.mine ? RM.bubbleMeText : RM.bubbleThemText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        message.mine ? RM.bubbleMe : RM.bubbleThem,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                Text(message.ts.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(
                        message.mine ? Color.white.opacity(0.8) : RM.onSurfaceVariant
                    )
            }
            if !message.mine { Spacer(minLength: 48) }
        }
        .contextMenu {
            Button("この端末から削除", systemImage: "trash", role: .destructive) {
                onDelete(message)
            }
        }
    }
}

// MARK: - Info

struct GroupInfoView: View {
    let groupId: String
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var showAdd = false

    private var group: ChatGroup? { store.group(groupId) }

    var body: some View {
        NavigationStack {
            List {
                if let group {
                    Section("メンバー") {
                        HStack(spacing: 12) {
                            Avatar(name: "自")
                            Text(group.ownerId == store.myId ? "自分（作成者）" : "自分")
                        }
                        ForEach(group.memberIds, id: \.self) { id in
                            HStack(spacing: 12) {
                                Avatar(name: name(for: id))
                                Text(name(for: id))
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.removeMember(id, from: group.id)
                                } label: {
                                    Label("削除", systemImage: "person.badge.minus")
                                }
                            }
                        }
                        Button { showAdd = true } label: {
                            Label("メンバーを追加", systemImage: "person.badge.plus")
                        }
                    }
                    Section {
                        if group.ownerId == store.myId || group.ownerId == nil {
                            Button("グループを削除（全員）", role: .destructive) {
                                confirmDelete = true
                            }
                        } else {
                            Button("グループを退出", role: .destructive) {
                                confirmLeave = true
                            }
                        }
                    }
                } else {
                    Text("グループが見つかりません")
                }
            }
            .navigationTitle(group?.name ?? "グループ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog(
                "グループを削除しますか？",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    store.deleteGroup(groupId)
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("グループと履歴を全員から削除します。")
            }
            .confirmationDialog(
                "グループを退出しますか？",
                isPresented: $confirmLeave,
                titleVisibility: .visible
            ) {
                Button("退出", role: .destructive) {
                    store.leaveGroup(groupId)
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この端末からグループと履歴を削除します。メンバーには退出が通知されます。")
            }
            .sheet(isPresented: $showAdd) {
                AddMembersView(groupId: groupId).environmentObject(store)
            }
        }
    }

    private func name(for id: String) -> String {
        store.contacts.first { $0.id == id }?.name ?? "メンバー"
    }
}

private struct AddMembersView: View {
    let groupId: String
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    private var candidates: [Contact] {
        guard let group = store.group(groupId) else { return [] }
        return store.contacts.filter { !$0.official && !group.memberIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if candidates.isEmpty {
                    Text("追加できる友だちがいません")
                        .foregroundStyle(RM.onSurfaceVariant)
                } else {
                    ForEach(candidates) { contact in
                        Button { toggle(contact.id) } label: {
                            HStack(spacing: 12) {
                                Avatar(name: contact.name)
                                Text(contact.name).foregroundStyle(RM.onSurface)
                                Spacer()
                                Image(
                                    systemName: selected.contains(contact.id)
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .foregroundStyle(
                                    selected.contains(contact.id)
                                        ? RM.primary : RM.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("メンバーを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        store.addMembers(Array(selected), to: groupId)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }
}
