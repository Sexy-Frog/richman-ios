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
    @EnvironmentObject private var locationProvider: LocationProvider
    @EnvironmentObject private var mapPresenter: MapPresenter

    @State private var draft = ""
    @State private var replyTo: ChatMessage?
    @State private var showReport = false
    @State private var showTTL = false
    @State private var showAttach = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var ttlSeconds = 0
    @State private var showLocationError = false
    @State private var imagePreview: ImagePreview?
    @State private var confirmClearChat = false
    @State private var showLocationPrimer = false

    private var messages: [ChatMessage] { store.messages(for: contact.id) }
    private var isBlocked: Bool { store.isBlocked(contact.id) }
    private var isOfficial: Bool { contact.official }
    private var canSend: Bool {
        !isBlocked && !isOfficial &&
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
                            let index = pair.offset
                            let message = pair.element
                            if index == 0 ||
                                !Calendar.current.isDate(messages[index - 1].ts, inSameDayAs: message.ts) {
                                DateDivider(date: message.ts)
                            }
                            MessageBubble(
                                message: message,
                                replyPreview: replyPreview(for: message),
                                onReply: { replyTo = $0 },
                                onDelete: {
                                    store.deleteMessage(
                                        $0, in: contact.id, everyone: false
                                    )
                                },
                                onDeleteEveryone: {
                                    store.deleteMessage(
                                        $0, in: contact.id, everyone: true
                                    )
                                },
                                onOpenImage: {
                                    imagePreview = ImagePreview(image: $0)
                                },
                                onOpenLocation: { target in
                                    mapPresenter.show(
                                        focusPeer: target.mine ? nil : contact.id
                                    )
                                }
                            )
                            .id(message.id)
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
            }

            if isOfficial {
                officialFooter
            } else {
                if let replyTo { replyBar(replyTo) }
                composer
            }
        }
        .background(RM.chatBg)
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.setActivePeer(contact.id)
            ttlSeconds = store.ttl(for: contact.id)
            store.purgeExpired(contact.id)
        }
        .onDisappear {
            store.setActivePeer(nil)
        }
        .toolbar {
            if !isOfficial {
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
                        Button("消えるメッセージ", systemImage: "timer") {
                            showTTL = true
                        }
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
        .sheet(isPresented: $showTTL, onDismiss: {
            store.setTTL(ttlSeconds, for: contact.id)
        }) {
            TTLSheet(seconds: $ttlSeconds)
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
        .confirmationDialog("送信する", isPresented: $showAttach, titleVisibility: .visible) {
            Button("写真") { showPhotos = true }
            Button("ファイル") { showFiles = true }
            Button("現在地") { sendCurrentLocation() }
            Button("キャンセル", role: .cancel) {}
        }
        .sheet(isPresented: $showLocationPrimer) {
            LocationPrimer().environmentObject(locationProvider)
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
        .alert("位置情報を送れません", isPresented: $showLocationError) {
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("位置情報の利用を許可し、現在地が取得できるまでお待ちください。共有はこの操作のときだけ行います。")
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

    private var officialBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "megaphone.fill")
            Text("公式アカウントからのお知らせです")
                .font(.footnote.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RM.surfaceVariant)
        .foregroundStyle(RM.onSurfaceVariant)
    }

    private var officialFooter: some View {
        Text("配信専用のため返信できません")
            .font(.caption)
            .foregroundStyle(RM.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RM.background)
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
        HStack(spacing: 8) {
            Rectangle()
                .fill(RM.primary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(target.mine ? "自分" : contact.name) に返信")
                    .font(.caption.weight(.semibold))
                Text(target.kind == .text ? target.body : "添付ファイル")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { replyTo = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RM.surface)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { showAttach = true } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(isBlocked ? RM.onSurfaceVariant : RM.primary)
            }
            .disabled(isBlocked)

            TextField(isBlocked ? "ブロック中" : "メッセージ", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RM.surface, in: Capsule())
                .overlay(Capsule().stroke(RM.outline, lineWidth: 1))
                .disabled(isBlocked)

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
        store.send(to: contact.id, text: text, replyTo: reply)
    }

    /// One-shot, user-initiated position share (never background tracking).
    private func sendCurrentLocation() {
        guard locationProvider.hasPermission else {
            showLocationPrimer = true
            return
        }
        guard let fix = locationProvider.location else {
            showLocationError = true
            return
        }
        store.sendLocation(
            to: contact.id,
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            accuracy: fix.horizontalAccuracy
        )
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
    let onOpenLocation: (ChatMessage) -> Void

    var body: some View {
        HStack(alignment: .bottom) {
            if message.mine { Spacer(minLength: 48) }
            VStack(alignment: message.mine ? .trailing : .leading, spacing: 3) {
                if let replyPreview {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(message.mine ? Color.white : RM.primary)
                            .frame(width: 2)
                        Text(replyPreview)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(message.mine ? Color.white.opacity(0.9) : RM.onSurfaceVariant)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (message.mine ? Color.white : RM.surfaceVariant).opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }

                content

                HStack(spacing: 3) {
                    Text(timeLabel)
                        .font(.caption2)
                        .foregroundStyle(RM.onSurfaceVariant)
                    if message.mine { deliveryIcon }
                }
            }
            if !message.mine { Spacer(minLength: 48) }
        }
        .swipeToReply { onReply(message) }
        .contextMenu {
            Button("返信", systemImage: "arrowshape.turn.up.left") { onReply(message) }
            if message.kind == .text {
                Button("コピー", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.body
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

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            bubbleText(message.body)
        case .image:
            if let name = message.mediaName, let image = MediaStore.image(named: name) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture { onOpenImage(image) }
            } else {
                bubbleLabel("画像", icon: "photo")
            }
        case .location:
            bubbleLabel("位置情報", icon: "location.fill")
                .onTapGesture { onOpenLocation(message) }
        case .file:
            VStack(alignment: .leading, spacing: 2) {
                Label(message.body, systemImage: "doc")
                    .lineLimit(1)
                if let size = message.fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption2)
                        .opacity(0.7)
                }
            }
            .foregroundStyle(message.mine ? RM.bubbleMeText : RM.bubbleThemText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.mine ? RM.bubbleMe : RM.bubbleThem,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
    }

    private func bubbleText(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(message.mine ? RM.bubbleMeText : RM.bubbleThemText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.mine ? RM.bubbleMe : RM.bubbleThem,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }

    private func bubbleLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(message.mine ? RM.bubbleMeText : RM.bubbleThemText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.mine ? RM.bubbleMe : RM.bubbleThem,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }

    private var timeLabel: String {
        message.ts.formatted(date: .omitted, time: .shortened)
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
        .font(.caption2)
        .foregroundStyle(message.delivery == .read ? RM.primary : RM.onSurfaceVariant)
    }
}

private struct DateDivider: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(RM.onSurfaceVariant)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RM.surfaceVariant, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今日" }
        if calendar.isDateInYesterday(date) { return "昨日" }
        return date.formatted(.dateTime.month().day())
    }
}

private struct TTLSheet: View {
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
