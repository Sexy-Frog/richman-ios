import SwiftUI
import UIKit

/// Swipe a message bubble to the right to reply, like Signal/Telegram.
/// The bubble follows the finger, a reply arrow appears, and releasing past the
/// threshold starts a reply. Vertical scrolling still works because the drag is
/// only consumed when horizontal movement dominates.
private struct SwipeToReplyModifier: ViewModifier {
    let onReply: () -> Void
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        ZStack(alignment: .leading) {
            if offset > 6 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RM.primary)
                    .opacity(Double(min(1, offset / 45)))
                    .scaleEffect(min(1.1, 0.7 + offset / 140))
            }
            content
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { value in
                            let width = value.translation.width
                            let height = value.translation.height
                            guard width > 0, abs(width) > abs(height) * 1.2 else {
                                return
                            }
                            offset = min(76, width)
                        }
                        .onEnded { _ in
                            let shouldReply = offset >= 48
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                offset = 0
                            }
                            if shouldReply {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onReply()
                            }
                        }
                )
        }
    }
}

extension View {
    /// Attach to a message bubble. The action runs when the user releases a
    /// rightward swipe past the threshold.
    func swipeToReply(_ action: @escaping () -> Void) -> some View {
        modifier(SwipeToReplyModifier(onReply: action))
    }
}
