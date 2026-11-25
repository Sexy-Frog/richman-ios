import SwiftUI
import Foundation

/// Full-screen call overlay (incoming / active). UI-only for now: the audio
/// engine and relay signalling are wired with the crypto/Tor increment.
struct CallOverlay: View {
    @EnvironmentObject private var calls: CallStore

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x1B2A4A), Color(hex: 0x0B0E11)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()
                Avatar(name: displayName)
                    .scaleEffect(1.7)
                Text(displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))

                Spacer()

                if calls.phase == .incoming {
                    HStack(spacing: 56) {
                        callButton("phone.down.fill", "拒否", .red) { calls.decline() }
                        callButton("phone.fill", "応答", .green) { calls.accept() }
                    }
                } else {
                    HStack(spacing: 36) {
                        callButton("mic.slash.fill", "ミュート", Color.white.opacity(0.18)) {}
                        callButton("speaker.wave.2.fill", "スピーカー", Color.white.opacity(0.18)) {}
                        callButton("phone.down.fill", "終了", .red) { calls.end() }
                    }
                }

                Spacer().frame(height: 50)
            }
            .padding(.horizontal, 24)
        }
    }

    private var displayName: String {
        calls.peerName.isEmpty ? "通話" : calls.peerName
    }

    private var status: String {
        switch calls.phase {
        case .incoming:
            return "着信"
        case .active:
            return "通話中 " + timeLabel
        case .idle:
            return ""
        }
    }

    private var timeLabel: String {
        String(format: "%02d:%02d", calls.seconds / 60, calls.seconds % 60)
    }

    private func callButton(
        _ icon: String,
        _ label: String,
        _ color: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(color, in: Circle())
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
