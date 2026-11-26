import SwiftUI
import UIKit

/// Swipe a message bubble toward its own side to reply, matching the Android
/// client: outgoing messages swipe left, incoming messages swipe right. The
/// bubble follows the finger, a reply arrow appears, and releasing past 52pt
/// starts a reply. Vertical scrolling is unaffected because only a
/// horizontal-dominant drag moves the bubble.
private struct SwipeToReplyModifier: ViewModifier {
    let outgoing: Bool
    let onReply: () -> Void
    @State private var offset: CGFloat = 0

    private var threshold: CGFloat { 52 }
    private var limit: CGFloat { 96 }

    func body(content: Content) -> some View {
        ZStack(alignment: outgoing ? .trailing : .leading) {
            if abs(offset) > 6 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RM.primary)
                    .scaleEffect(x: outgoing ? -1 : 1, y: 1)
                    .opacity(Double(min(1, abs(offset) / 45)))
                    .scaleEffect(min(1.1, 0.7 + abs(offset) / 140))
            }
            content
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { value in
                            let width = value.translation.width
                            let height = value.translation.height
                            guard abs(width) > abs(height) * 1.2 else { return }
                            if outgoing {
                                guard width < 0 else { return }
                                offset = max(-limit, width)
                            } else {
                                guard width > 0 else { return }
                                offset = min(limit, width)
                            }
                        }
                        .onEnded { _ in
                            let fired = outgoing
                                ? offset <= -threshold
                                : offset >= threshold
                            withAnimation(.easeOut(duration: 0.15)) {
                                offset = 0
                            }
                            if fired {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onReply()
                            }
                        }
                )
        }
    }
}

extension View {
    /// Attach to a message bubble. `outgoing` chooses the swipe direction
    /// (left for mine, right for received), like the Android client.
    func swipeToReply(outgoing: Bool, _ action: @escaping () -> Void) -> some View {
        modifier(SwipeToReplyModifier(outgoing: outgoing, onReply: action))
    }
}
