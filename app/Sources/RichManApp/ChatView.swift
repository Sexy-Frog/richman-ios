import SwiftUI

/// 1:1 chat backed by the shared `ChatStore`. UI parity with the Android client:
/// date dividers, timestamps, delivery ticks, reply, disappearing-message setting,
/// block/report, and demo attachments. The relay send/receive loop replaces the
/// local echo at `ChatStore.send/receive` next.
struct ChatView: View {
    let contact: Contact
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var calls: CallStore
    @AppStorage("rm.ttl") private var ttlSeconds = 0

    @State private var draft = ""
    @State private var replyTo: ChatMessage?
    @State private var showReport = false
    @State private var showTTL = false
    @State private var showAttach = false

    private var messages: [ChatMessage] { store.messages(for: contact.id) }
    private var isBlocked: Bool { store.isBlocked(contact.id) }
    private var canSend: Bool {
        !isBlocked && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if isBlocked { blockedBanner }

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
                                onReply: { replyTo = $0 }
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

            if let replyTo { replyBar(replyTo) }
            composer
        }
        .background(RM.chatBg)
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.markRead(contact.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { calls.start(contact.name) } label: {
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(contact: contact).environmentObject(store)
        }
        .sheet(isPresented: $showTTL) {
            TTLSheet(seconds: $ttlSeconds)
        }
        .confirmationDialog("送信する", isPresented: $showAttach, titleVisibility: .visible) {
            Button("画像（デモ）") { store.send(to: contact.id, text: "画像", kind: .image) }
            Button("ファイル（デモ）") { store.send(to: contact.id, text: "ファイル", kind: .file) }
            Button("キャンセル", role: .cancel) {}
        }
        .task {
            // Simulated transport acks so the ticks match the Android UI.
            store.markDelivered(contact.id)
            try? await Task.sleep(nanoseconds: 700_000_000)
            store.markMyMessagesRead(contact.id)
        }
    }

    // MARK: pieces

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

    private func replyBar(_ target: ChatMessage) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(RM.primary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(target.mine ? "自分" : contact.name) に返信")
                    .font(.caption.weight(.semibold))
                Text(target.body)
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
        guard let id = message.replyTo else { return nil }
        return messages.first { $0.id == id }?.body
    }

    private func send() {
        let text = draft
        let reply = replyTo?.id
        draft = ""
        replyTo = nil
        store.send(to: contact.id, text: text, replyTo: reply)
    }
}

// MARK: - bubbles

private struct MessageBubble: View {
    let message: ChatMessage
    let replyPreview: String?
    let onReply: (ChatMessage) -> Void

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
        .contextMenu {
            Button("返信", systemImage: "arrowshape.turn.up.left") { onReply(message) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            Text(message.body)
                .foregroundStyle(message.mine ? RM.bubbleMeText : RM.bubbleThemText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.mine ? RM.bubbleMe : RM.bubbleThem,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        case .image:
            Label("画像", systemImage: "photo")
                .foregroundStyle(message.mine ? RM.bubbleMeText : RM.bubbleThemText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.mine ? RM.bubbleMe : RM.bubbleThem,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        case .file:
            Label("ファイル", systemImage: "doc")
                .foregroundStyle(message.mine ? RM.bubbleMeText : RM.bubbleThemText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    message.mine ? RM.bubbleMe : RM.bubbleThem,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
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
                    Text("この端末の表示設定です。送信側の自動削除は次の移植で有効になります。")
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
