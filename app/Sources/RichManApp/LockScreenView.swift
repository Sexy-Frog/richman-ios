import SwiftUI

/// PIN unlock screen. The parent decides what "wipe" means after the configured
/// number of wrong attempts.
struct LockScreenView: View {
    @EnvironmentObject private var lock: LockStore
    let onWipe: () -> Void

    @State private var pin = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            RM.background.ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(RM.primary)

                Text("暗証番号")
                    .font(.title2.weight(.bold))
                Text("ロックを解除してください")
                    .font(.subheadline)
                    .foregroundStyle(RM.onSurfaceVariant)

                SecureField("暗証番号", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .multilineTextAlignment(.center)
                    .font(.title3.monospaced())
                    .padding()
                    .background(RM.surface, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 32)
                    .onSubmit(unlock)

                Button("解除", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .tint(RM.primary)
                    .disabled(pin.count < 4)

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(RM.error)
                }

                if lock.failedAttempts > 0 {
                    Text("あと \(lock.attemptsLeft) 回でこの端末のデータを消去します")
                        .font(.caption2)
                        .foregroundStyle(RM.onSurfaceVariant)
                }

                Spacer()
            }
        }
        .onAppear { focused = true }
    }

    private func unlock() {
        if lock.unlock(pin) {
            pin = ""
            error = nil
        } else {
            pin = ""
            if lock.failedAttempts >= lock.wipeAfter {
                onWipe()
            } else {
                error = "暗証番号が違います"
            }
        }
    }
}
