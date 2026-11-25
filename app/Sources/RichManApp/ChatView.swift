import SwiftUI

/// 1:1 chat, backed by the shared `ChatStore`. Sends echo into the store for now;
/// the relay send/receive path wires in at `ChatStore.send/receive` next.
struct ChatView: View {
    let contact: Contact
    @EnvironmentObject private var store: ChatStore
    @State private var draft: String = ""
    @State private var showReport = false

    private var messages: [ChatMessage] { store.messages(for: contact.id) }
    private var isBlocked: Bool { store.isBlocked(contact.id) }

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
                .onChange(of: messages.count) {
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            composer
        }
        .background(RM.chatBg)
        .navigationTitle(contact.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.markRead(contact.id) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(isBlocked ? "ブロックを解除" : "ブロック",
                           systemImage: isBlocked ? "hand.raised.slash" : "hand.raised") {
                        store.setBlocked(contact.id, !isBlocked)
                    }
                    Button("通報", systemImage: "flag", role: .destructive) { showReport = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showReport) { ReportSheet(contact: contact).environmentObject(store) }
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
        store.send(to: contact.id, text: draft)
        draft = ""
    }
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
