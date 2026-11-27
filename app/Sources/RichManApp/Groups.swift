import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
    @State private var replyTo: ChatMessage?
    @FocusState private var composerFocused: Bool
    @State private var showInfo = false
    @State private var showTTL = false
    @State private var ttlSeconds = 0
    @State private var showAttach = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var bubbleGeometry = ChatBubbleGeometry()
    @Environment(\.dismiss) private var dismiss

    private var messages: [ChatMessage] { store.messages(forGroup: group.id) }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if ttlSeconds > 0 { ttlBanner }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { pair in
                            let index = pair.offset
                            let message = pair.element
                            if index == 0 ||
                                !Calendar.current.isDate(
                                    messages[index - 1].ts,
                                    inSameDayAs: message.ts
                                ) {
                                DateDivider(date: message.ts)
                            }
                            GroupBubble(
                                message: message,
                                mentioned: message.mentions?
                                    .contains(store.myId) == true,
                                onReply: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        replyTo = $0
                                    }
                                    composerFocused = true
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                },
                                onDelete: {
                                    store.deleteGroupMessage($0, in: group.id)
                                },
                                onDeleteEveryone: {
                                    store.deleteGroupMessage(
                                        $0, in: group.id, everyone: true
                                    )
                                }
                            )
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
                .onAppear {
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onPreferenceChange(BubbleFrameKey.self) {
                    bubbleGeometry.frames = $0
                }
            }
            mentionSuggestions
            composer
        }
        .background(RM.chatBg)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(group.memberIds.count + 1)人のグループ")
                        .font(.system(size: 10))
                        .foregroundStyle(RM.onSurfaceVariant)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showTTL = true } label: { Image(systemName: "timer") }
                    .accessibilityLabel("消えるメッセージ")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
            }
        }
        .sheet(isPresented: $showInfo) {
            GroupInfoView(groupId: group.id).environmentObject(store)
        }
        .sheet(isPresented: $showTTL, onDismiss: {
            store.setGroupTTL(ttlSeconds, for: group.id)
        }) {
            TTLSheet(seconds: $ttlSeconds)
        }
        .onAppear {
            store.setActiveGroup(group.id)
            ttlSeconds = store.ttl(for: group.id)
            store.purgeExpiredGroup(group.id)
        }
        .task(id: group.id) {
            while !Task.isCancelled {
                store.purgeExpiredGroup(group.id)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onDisappear { store.setActiveGroup(nil) }
        .confirmationDialog("送信する", isPresented: $showAttach, titleVisibility: .visible) {
            Button("写真") { showPhotos = true }
            Button("ファイル") { showFiles = true }
            Button("キャンセル", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .fileImporter(
            isPresented: $showFiles,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            store.sendFile(toGroup: group.id, url: url)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.sendImage(toGroup: group.id, data: data)
                }
                photoItem = nil
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if let replyTo { replyBar(replyTo) }
            HStack(alignment: .bottom, spacing: 8) {
                Button { showAttach = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(RM.primary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                Menu {
                    Button("@全員") { insertMention("全員") }
                    Divider()
                    ForEach(group.memberIds, id: \.self) { id in
                        if let contact = store.contact(id) {
                            Button("@\(contact.name)") {
                                insertMention(contact.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "at")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(RM.primary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                TextField("メッセージ", text: $draft, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 40)
                    .background(RM.surface, in: Capsule())
                    .overlay(Capsule().stroke(RM.outline, lineWidth: 1))
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(canSend ? 1 : 0.75))
                        .frame(width: 40, height: 40)
                        .background(
                            canSend ? RM.primary : RM.onSurfaceVariant.opacity(0.35),
                            in: Circle()
                        )
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(RM.background)
    }

    private var ttlBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
            Text("消えるメッセージ: \(ttlLabel(ttlSeconds))")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(RM.onSurfaceVariant)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(RM.surface)
    }

    private func ttlLabel(_ seconds: Int) -> String {
        switch seconds {
        case 3600: return "1時間"
        case 86_400: return "1日"
        case 604_800: return "7日"
        default: return "オフ"
        }
    }

    private func replyBar(_ message: ChatMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(RM.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("返信")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(RM.primary)
                Text("\(message.mine ? "自分" : (message.senderName ?? "メンバー")): \(previewText(message))")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(RM.onSurfaceVariant)
            }
            Spacer()
            Button { replyTo = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(RM.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RM.primary.opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle().fill(RM.primary).frame(width: 3)
        }
    }

    private func previewText(_ message: ChatMessage) -> String {
        switch message.kind {
        case .image: return "画像"
        case .file: return "ファイル"
        case .location: return "位置情報"
        case .text: return message.body
        }
    }

    private var mentionQuery: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex {
            let prev = draft[draft.index(before: at)]
            guard prev == " " || prev == "\n" else { return nil }
        }
        let tail = draft[draft.index(after: at)...]
        guard !tail.contains(" "), !tail.contains("\n") else { return nil }
        return String(tail)
    }

    private var mentionCandidates: [(id: String, name: String)] {
        guard let query = mentionQuery else { return [] }
        var list: [(id: String, name: String)] = [("all", "全員")]
        for id in group.memberIds {
            if let contact = store.contact(id) {
                list.append((id, contact.name))
            }
        }
        guard !query.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private var mentionSuggestions: some View {
        if mentionQuery != nil, !mentionCandidates.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(mentionCandidates, id: \.id) { candidate in
                        Button {
                            applyMention(candidate.name)
                        } label: {
                            Text("@\(candidate.name)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(RM.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(RM.surface, in: Capsule())
                                .overlay(Capsule().stroke(RM.outline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(RM.background)
        }
    }

    private func applyMention(_ name: String) {
        guard let at = draft.lastIndex(of: "@") else {
            insertMention(name)
            return
        }
        draft = String(draft[..<at]) + "@\(name) "
    }

    private func insertMention(_ name: String) {
        if !draft.isEmpty, !draft.hasSuffix(" ") { draft += " " }
        draft += "@\(name) "
    }

    private func send() {
        let text = draft
        let reply = replyTo
        draft = ""
        replyTo = nil
        store.send(toGroup: group.id, text: text, replyTo: reply)
    }
}

private struct GroupBubble: View {
    let message: ChatMessage
    let mentioned: Bool
    let onReply: (ChatMessage) -> Void
    let onDelete: (ChatMessage) -> Void
    let onDeleteEveryone: (ChatMessage) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if message.mine {
                Spacer(minLength: 44)
            } else {
                meta
            }

            bubble
                .swipeToReply(outgoing: message.mine) { onReply(message) }
                .recordBubbleFrame()
                .frame(maxWidth: 300, alignment: message.mine ? .trailing : .leading)

            if message.mine {
                meta
            } else {
                Spacer(minLength: 44)
            }
        }
        .contextMenu {
            Button("返信", systemImage: "arrowshape.turn.up.left") {
                onReply(message)
            }
            Button("この端末から削除", systemImage: "trash", role: .destructive) {
                onDelete(message)
            }
            if message.mine {
                Button("全員から削除", systemImage: "trash.slash", role: .destructive) {
                    onDeleteEveryone(message)
                }
            }
        }
    }

    private var meta: some View {
        Text(ChatTime.label(message.ts))
            .font(.system(size: 10))
            .foregroundStyle(RM.onSurfaceVariant)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !message.mine, let sender = message.senderName, !sender.isEmpty {
                Text(sender)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RM.primary)
            }
            if mentioned, !message.mine {
                Text("あなた宛て")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RM.primary)
            }
            if let name = message.replyName, let text = message.replyText {
                replyQuote(name: name, text: text)
            }
            content
        }
        .padding(bubblePadding)
        .background(
            BubbleStyle.color(mine: message.mine, mentioned: mentioned),
            in: BubbleStyle.shape(mine: message.mine)
        )
    }

    private var bubblePadding: EdgeInsets {
        message.kind == .image
            ? EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            : EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
    }

    private var textColor: Color {
        message.mine ? RM.bubbleMeText : RM.bubbleThemText
    }

    private var subColor: Color {
        message.mine ? RM.bubbleMeText.opacity(0.8) : RM.onSurfaceVariant
    }

    private func replyQuote(name: String, text: String) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(message.mine ? Color.white : RM.primary)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(message.mine ? Color.white : RM.primary)
                Text(text)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(
                        message.mine ? Color.white.opacity(0.85) : RM.onSurfaceVariant
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (message.mine ? Color.white : RM.primary).opacity(0.14),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            Text(message.body)
                .font(.system(size: 15))
                .lineSpacing(2)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        case .image:
            if let name = message.mediaName, let image = MediaStore.image(named: name) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Label("画像", systemImage: "photo")
                    .foregroundStyle(textColor)
            }
        case .file:
            fileContent
        case .location:
            Label("位置情報", systemImage: "location.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textColor)
        }
    }

    @ViewBuilder
    private var fileContent: some View {
        let body = HStack(spacing: 10) {
            Image(systemName: "paperclip")
                .font(.system(size: 18))
                .foregroundStyle(message.mine ? RM.bubbleMeText : RM.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.body)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(textColor)
                Text(fileSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(subColor)
            }
        }
        if let name = message.mediaName {
            ShareLink(item: MediaStore.fileURL(named: name)) {
                body
            }
        } else {
            body
        }
    }

    private var fileSubtitle: String {
        let size = message.fileSize.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? "ファイル"
        return message.mediaName == nil
            ? "\(size)・受信待ち"
            : "\(size)・タップで共有"
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
                                if group.ownerId == store.myId {
                                    Button(role: .destructive) {
                                        store.removeMember(id, from: group.id)
                                    } label: {
                                        Label("削除", systemImage: "person.badge.minus")
                                    }
                                }
                            }
                        }
                        if group.ownerId == store.myId {
                            Button { showAdd = true } label: {
                                Label("メンバーを追加", systemImage: "person.badge.plus")
                            }
                        }
                    }
                    Section {
                        if group.ownerId == store.myId {
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
