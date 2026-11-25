import SwiftUI

/// 1:1 chat. UI-complete against local state; the send/receive path is wired to
/// the relay + CryptoProvider in a later increment (today it echoes locally so
/// the screen is testable in the Simulator).
struct ChatView: View {
    let conversation: Conversation
    @EnvironmentObject private var model: AppModel
    @State private var messages: [ChatMessage] = []
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(messages) { m in
                            MessageBubble(message: m).id(m.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            composer
        }
        .background(RM.chatBg)
        .navigationTitle(conversation.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("メッセージ", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(RM.surface, in: Capsule())
                .overlay(Capsule().stroke(RM.outline, lineWidth: 1))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? RM.primary : RM.onSurfaceVariant)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RM.background)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        messages.append(ChatMessage(id: UUID().uuidString, body: body, mine: true, ts: Date()))
        draft = ""
        // TODO: encrypt via model.crypto + send over the relay (next increment).
    }
}

struct ChatMessage: Identifiable, Hashable {
    let id: String
    var body: String
    var mine: Bool
    var ts: Date
}

private struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack {
            if message.mine { Spacer(minLength: 48) }
            Text(message.body)
                .foregroundStyle(message.mine ? RM.bubbleMeText : RM.bubbleThemText)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(message.mine ? RM.bubbleMe : RM.bubbleThem,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !message.mine { Spacer(minLength: 48) }
        }
    }
}
