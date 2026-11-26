import SwiftUI
import UIKit

/// Shared geometry for the chat screens. Bubble frames are published in the
/// window space so the swipe-back gesture can tell an empty area from a
/// message bubble. The frames live in a plain reference type so scrolling and
/// reply swipes do not trigger a SwiftUI re-render.
final class ChatBubbleGeometry {
    var frames: [CGRect] = []
}

enum BubbleStyle {
    /// Android's bubbleShape: rounded everywhere except a 4pt corner on the
    /// sender's side.
    static func shape(mine: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16,
            bottomLeadingRadius: mine ? 16 : 4,
            bottomTrailingRadius: mine ? 4 : 16,
            topTrailingRadius: 16,
            style: .continuous
        )
    }

    static func color(mine: Bool, mentioned: Bool = false) -> Color {
        if mine { return RM.bubbleMe }
        if mentioned { return RM.primary.opacity(0.16) }
        return RM.bubbleThem
    }
}

enum ChatTime {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日(E)"
        return formatter
    }()

    /// Android parity: 24-hour time within the last day, otherwise M/d.
    static func label(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 86_400 {
            return clock.string(from: date)
        }
        return shortDate.string(from: date)
    }

    static func dayLabel(_ date: Date) -> String {
        day.string(from: date)
    }
}

struct BubbleFrameKey: PreferenceKey {
    static var defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct BubbleFrameRecorder: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BubbleFrameKey.self,
                    value: [proxy.frame(in: .global)]
                )
            }
        )
    }
}

extension View {
    func recordBubbleFrame() -> some View {
        modifier(BubbleFrameRecorder())
    }
}

struct DateDivider: View {
    let date: Date

    var body: some View {
        Text(ChatTime.dayLabel(date))
            .font(.system(size: 10))
            .foregroundStyle(RM.onSurfaceVariant)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(RM.surfaceVariant.opacity(0.8), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

/// Swipe right in the empty left half of the chat to go back to the talks list.
/// A drag that starts on a bubble is left to the swipe-to-reply gesture.
private struct SwipeBackToTalksModifier: ViewModifier {
    let geometry: ChatBubbleGeometry
    let onBack: () -> Void

    @State private var offset: CGFloat = 0
    @State private var engaged = false
    @State private var width: CGFloat = 393

    func body(content: Content) -> some View {
        content
            .offset(x: offset * 0.35)
            .overlay(alignment: .leading) {
                if offset > 8 {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                        Text("トーク一覧")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RM.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RM.surface, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(.leading, 14)
                    .opacity(Double(min(1, (offset - 8) / 56)))
                    .allowsHitTesting(false)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in width = new }
                }
            )
            .simultaneousGesture(gesture)
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .global)
            .onChanged { value in
                if !engaged {
                    guard candidate(value) else { return }
                    engaged = true
                }
                offset = max(0, value.translation.width)
            }
            .onEnded { value in
                let fire = engaged && value.translation.width >= 72
                engaged = false
                if fire {
                    offset = 0
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onBack()
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { offset = 0 }
                }
            }
    }

    private func candidate(_ value: DragGesture.Value) -> Bool {
        let dx = value.translation.width
        let dy = value.translation.height
        guard dx > 0, abs(dx) > abs(dy) * 1.4 else { return false }
        let start = value.startLocation
        // Leave the left edge to the system interactive-pop gesture.
        guard start.x > 24, start.x < width * 0.5 else { return false }
        return !geometry.frames.contains {
            $0.insetBy(dx: -8, dy: -8).contains(start)
        }
    }
}

extension View {
    func swipeBackToTalks(
        geometry: ChatBubbleGeometry,
        onBack: @escaping () -> Void
    ) -> some View {
        modifier(SwipeBackToTalksModifier(geometry: geometry, onBack: onBack))
    }
}
