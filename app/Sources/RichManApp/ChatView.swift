import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// 1:1 chat backed by the shared `ChatStore`. UI parity with the Android client:
/// date dividers, timestamps, delivery ticks, reply, disappearing messages,
/// attachments, block/report, and a one-way official account.
struct ChatView: View {
    let contact: Contact
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var calls: CallStore

    @State private var draft = ""
    @State private var replyTo: ChatMessage?
    @FocusState private var composerFocused: Bool
    @State private var showReport = false
    @State private var showTTL = false
    @State private var showProfile = false
    @State private var confirmRemove = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var ttlSeconds = 0
    @State private var imagePreview: ImagePreview?
    @State private var confirmClearChat = false
    @State private var bubbleGeometry = ChatBubbleGeometry()
    @State private var joinedGroup: ChatGroup?
    @Environment(\.dismiss) private var dismiss

    private var messages: [ChatMessage] { store.messages(for: contact.id) }
    private var isBlocked: Bool { store.isBlocked(contact.id) }
    private var isOfficial: Bool { contact.official }
    private var canSend: Bool {
        !isBlocked &&
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if isOfficial {
                officialBanner
            } else if isBlocked {
                blockedBanner
            }
            if ttlSeconds > 0 { ttlBanner }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { pair in
                            chatRow(pair.element, index: pair.offset)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
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
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(BubbleFrameKey.self) {
                    bubbleGeometry.frames = $0
                }
            }

            if !isOfficial, let replyTo { replyBar(replyTo) }
            composer
        }
        .background(RM.chatBg)
        .overlay {
            if showProfile {
                profilePopup
            }
        }
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.setActivePeer(contact.id)
            ttlSeconds = store.ttl(for: contact.id)
            store.purgeExpired(contact.id)
        }
        .onDisappear {
            store.sendTyping(false, to: contact.id)
            store.setActivePeer(nil)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showProfile = true }
                } label: {
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            Text(contact.name)
                                .font(.headline)
                                .lineLimit(1)
                            if isOfficial {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(RM.primary)
                            }
                        }
                        Text(store.isTyping(contact.id) ? "入力中…" : "端末間暗号化")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                store.isTyping(contact.id)
                                    ? RM.primary
                                    : RM.onSurfaceVariant
                            )
                            .animation(.easeOut(duration: 0.15), value: store.isTyping(contact.id))
                    }
                }
                .buttonStyle(.plain)
            }
            if !isOfficial {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTTL = true } label: {
                        Image(systemName: "timer")
                    }
                    .accessibilityLabel("消えるメッセージ")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                    calls.startCall(peerId: contact.id, name: contact.name)
                } label: {
                        Image(systemName: "phone.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(
                            isBlocked ? "ブロックを解除" : "ブロック",
                            systemImage: isBlocked ? "hand.raised.slash" : "hand.raised"
                        ) {
                            store.setBlocked(contact.id, !isBlocked)
                        }
                        Button("通報", systemImage: "flag", role: .destructive) {
                            showReport = true
                        }
                        Divider()
                        Button("トークを削除", systemImage: "trash", role: .destructive) {
                            confirmClearChat = true
                        }

                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(contact: contact).environmentObject(store)
        }
        .confirmationDialog(
            "トークを削除しますか？",
            isPresented: $confirmClearChat,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                store.clearChat(contact.id)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この端末からメッセージ履歴を削除します。友だちは残ります。")
        }
        .confirmationDialog(
            "友だちを削除しますか？",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                store.removeContact(contact.id)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この端末から友だちとトーク履歴を削除します。")
        }
        .sheet(isPresented: $showTTL, onDismiss: {
            store.setTTL(ttlSeconds, for: contact.id)
        }) {
            TTLSheet(seconds: $ttlSeconds)
        }
        .sheet(item: $joinedGroup) { group in
            NavigationStack {
                GroupChatView(group: group)
            }
            .environmentObject(store)
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
            store.sendFile(to: contact.id, url: url)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.sendImage(to: contact.id, data: data)
                }
                photoItem = nil
            }
        }
        .sheet(item: $imagePreview) { preview in
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: preview.image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { imagePreview = nil }
                    }
                }
                .toolbarBackground(.black, for: .navigationBar)
            }
        }
        .task {
            store.markDelivered(contact.id)
            try? await Task.sleep(nanoseconds: 700_000_000)
            store.markMyMessagesRead(contact.id)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                store.purgeExpired(contact.id)
            }
        }
    }

    // MARK: pieces

    @ViewBuilder
    private func chatRow(_ message: ChatMessage, index: Int) -> some View {
        if index == 0 ||
            !Calendar.current.isDate(
                messages[index - 1].ts,
                inSameDayAs: message.ts
            ) {
            DateDivider(date: message.ts)
        }
        if message.system == true {
            Text(message.body)
                .font(.system(size: 11))
                .foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .id(message.id)
        } else {
            MessageBubble(
                message: message,
                replyPreview: replyPreview(for: message),
                onReply: handleReply,
                onDelete: { store.deleteMessage($0, in: contact.id, everyone: false) },
                onDeleteEveryone: { store.deleteMessage($0, in: contact.id, everyone: true) },
                onOpenImage: { imagePreview = ImagePreview(image: $0) },
                onAcceptInvite: acceptInvite,
                onDeclineInvite: declineInvite
            )
            .id(message.id)
        }
    }

    private func handleReply(_ target: ChatMessage) {
        withAnimation(.easeOut(duration: 0.15)) {
            replyTo = target
        }
        composerFocused = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func acceptInvite(_ message: ChatMessage) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if let group = store.acceptGroupInvite(message, in: contact.id) {
            joinedGroup = group
        }
    }

    private func declineInvite(_ message: ChatMessage) {
        store.declineGroupInvite(message, in: contact.id)
    }

    private var profilePopup: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { showProfile = false }
                }

            VStack(spacing: 18) {
                Avatar(name: contact.name, size: 76)
                Text(contact.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)

                HStack(spacing: 22) {
                    popupAction(
                        icon: store.isMuted(contact.id) ? "bell.slash.fill" : "bell.fill",
                        title: store.isMuted(contact.id) ? "ミュート解除" : "ミュート"
                    ) {
                        store.setMuted(contact.id, !store.isMuted(contact.id))
                    }
                    if !isOfficial {
                        popupAction(icon: "flag", title: "通報") {
                            withAnimation { showProfile = false }
                            showReport = true
                        }
                        popupAction(
                            icon: "person.badge.minus",
                            title: "削除",
                            tint: RM.error
                        ) {
                            withAnimation { showProfile = false }
                            confirmRemove = true
                        }
                    }
                }

                Button("閉じる") {
                    withAnimation(.easeOut(duration: 0.15)) { showProfile = false }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(RM.onSurfaceVariant)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(RM.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
            .padding(30)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private func popupAction(
        icon: String,
        title: String,
        tint: Color = RM.primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.12), in: Circle())
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(width: 72)
        }
        .buttonStyle(.plain)
    }

    private var officialBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "megaphone.fill")
            Text("公式アカウント")
                .font(.footnote.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RM.surfaceVariant)
        .foregroundStyle(RM.onSurfaceVariant)
    }

    private var blockedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
            Text("このユーザーをブロックしています")
                .font(.footnote.weight(.semibold))
            Spacer()
            Button("解除") { store.setBlocked(contact.id, false) }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RM.surfaceVariant)
        .foregroundStyle(RM.onSurfaceVariant)
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

    private func replyBar(_ target: ChatMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(RM.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text("返信")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(RM.primary)
                Text("\(target.mine ? "自分" : contact.name): \(target.kind == .text ? target.body : "添付")")
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

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !isOfficial {
                Menu {
                    Button("写真", systemImage: "photo") { showPhotos = true }
                    Button("ファイル", systemImage: "doc") { showFiles = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isBlocked ? RM.onSurfaceVariant : RM.primary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .disabled(isBlocked)
            }

            TextField(isBlocked ? "ブロック中" : "メッセージ", text: $draft, axis: .vertical)
                .font(.body)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused($composerFocused)
                .onChange(of: draft) { _, text in
                    store.sendTyping(!text.isEmpty, to: contact.id)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 40)
                .background(RM.surface, in: Capsule())
                .overlay(Capsule().stroke(RM.outline, lineWidth: 1))
                .disabled(isBlocked)

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
        .background(RM.background)
    }

    private func replyPreview(for message: ChatMessage) -> String? {
        if let id = message.replyTo,
           let target = messages.first(where: { $0.id == id || $0.remoteId == id }) {
            let who = target.mine ? "自分" : (target.senderName ?? contact.name)
            let body = target.body.isEmpty
                ? (target.kind == .image ? "画像" : target.kind == .file ? "ファイル" : "位置情報")
                : target.body
            return "\(who): \(body)"
        }
        if let name = message.replyName, let text = message.replyText {
            return "\(name): \(text)"
        }
        return message.replyText
    }

    private func ttlLabel(_ seconds: Int) -> String {
        switch seconds {
        case 3600: return "1時間"
        case 86_400: return "1日"
        case 604_800: return "7日"
        default: return "オフ"
        }
    }

    private func send() {
        let text = draft
        let reply = replyTo?.id
        draft = ""
        replyTo = nil
        store.sendTyping(false, to: contact.id)
        store.send(to: contact.id, text: text, replyTo: reply)
    }
}

// MARK: - bubbles

private struct ImagePreview: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct MessageBubble: View {
    let message: ChatMessage
    let replyPreview: String?
    let onReply: (ChatMessage) -> Void
    let onDelete: (ChatMessage) -> Void
    let onDeleteEveryone: (ChatMessage) -> Void
    let onOpenImage: (UIImage) -> Void
    let onAcceptInvite: (ChatMessage) -> Void
    let onDeclineInvite: (ChatMessage) -> Void

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
            Button("返信", systemImage: "arrowshape.turn.up.left") { onReply(message) }
            if message.kind == .text {
                Button("コピー", systemImage: "doc.on.doc") {
                    // Expire the pasteboard automatically so a copied secret
                    // does not linger for other apps.
                    UIPasteboard.general.setItems(
                        [[UTType.utf8PlainText.identifier: message.body as Any]],
                        options: [.expirationDate: Date().addingTimeInterval(60)]
                    )
                }
            }
            if message.kind == .file, let name = message.mediaName {
                ShareLink(item: MediaStore.fileURL(named: name)) {
                    Label("ファイルを共有", systemImage: "square.and.arrow.up")
                }
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

    /// Timestamp sits outside the bubble like the Android client: left of
    /// incoming messages, right of outgoing ones, bottom-aligned.
    private var meta: some View {
        HStack(spacing: 3) {
            Text(ChatTime.label(message.ts))
                .font(.system(size: 10))
                .foregroundStyle(RM.onSurfaceVariant)
            if message.mine { deliveryIcon }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let replyPreview {
                replyQuote(replyPreview)
            }
            content
        }
        .padding(bubblePadding)
        .background(
            BubbleStyle.color(mine: message.mine),
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

    private func replyQuote(_ text: String) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(message.mine ? Color.white : RM.primary)
                .frame(width: 2)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(
                    message.mine ? Color.white.opacity(0.85) : RM.onSurfaceVariant
                )
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
                    .onTapGesture { onOpenImage(image) }
            } else {
                Label("画像", systemImage: "photo")
                    .foregroundStyle(textColor)
            }
        case .location:
            Label("位置情報", systemImage: "location.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textColor)
        case .file:
            fileContent
        case .invite:
            inviteContent
        }
    }

    private var inviteContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("グループへの招待")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(message.mine ? Color.white : RM.primary)

            Text(message.inviteName ?? message.body)
                .font(.system(size: 16, weight: .bold))
                .lineLimit(2)
                .foregroundStyle(textColor)

            Text("\((message.inviteMembers?.count ?? 0) + 2)人のグループ")
                .font(.system(size: 11))
                .foregroundStyle(subColor)

            switch message.inviteAccepted {
            case true?:
                Label("参加済み", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(message.mine ? Color.white : RM.primary)
            case false?:
                Label("辞退しました", systemImage: "xmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(subColor)
            default:
                HStack(spacing: 8) {
                    Button { onAcceptInvite(message) } label: {
                        Text("参加")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(RM.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button { onDeclineInvite(message) } label: {
                        Text("拒否")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(message.mine ? Color.white : RM.onSurface)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                message.mine
                                    ? Color.white.opacity(0.16)
                                    : RM.surfaceVariant,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 230, alignment: .leading)
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

    @ViewBuilder
    private var deliveryIcon: some View {
        Group {
            switch message.delivery {
            case .sent:
                Image(systemName: "checkmark")
            case .delivered:
                Image(systemName: "checkmark.circle")
            case .read:
                Image(systemName: "checkmark.circle.fill")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(message.delivery == .read ? RM.primary : RM.onSurfaceVariant)
    }
}

struct TTLSheet: View {
    @Binding var seconds: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("消えるメッセージ", selection: $seconds) {
                        Text("オフ").tag(0)
                        Text("1時間").tag(3600)
                        Text("1日").tag(86_400)
                        Text("7日").tag(604_800)
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text("この端末の履歴に適用されます。送信側の自動削除は次の移植で有効になります。")
                }
            }
            .navigationTitle("消えるメッセージ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
