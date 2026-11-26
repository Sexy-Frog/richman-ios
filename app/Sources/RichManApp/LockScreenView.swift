import SwiftUI
import UIKit

/// PIN unlock screen with a custom keypad (no system keyboard). Supports the
/// 4–8 digit PINs accepted by onboarding and change-PIN.
struct LockScreenView: View {
    @EnvironmentObject private var lock: LockStore
    let onWipe: () -> Void

    @State private var digits = ""
    @State private var error: String?

    private let maxDigits = 8

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

                dots
                    .padding(.vertical, 6)

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

                keypad
                    .padding(.top, 4)

                Button("解除", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .tint(RM.primary)
                    .disabled(digits.count < 4)

                Spacer()
            }
            .padding(.horizontal, 28)
        }
    }

    private var dots: some View {
        HStack(spacing: 14) {
            ForEach(0..<max(4, digits.count), id: \.self) { index in
                Circle()
                    .fill(index < digits.count ? RM.primary : RM.outline)
                    .frame(width: 14, height: 14)
            }
        }
        .animation(.easeOut(duration: 0.12), value: digits.count)
    }

    private var keypad: some View {
        VStack(spacing: 14) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 22) {
                    ForEach(0..<3, id: \.self) { column in
                        digitKey("\(row * 3 + column + 1)")
                    }
                }
            }
            HStack(spacing: 22) {
                Color.clear.frame(width: 70, height: 70)
                digitKey("0")
                Button(action: deleteDigit) {
                    Image(systemName: "delete.left")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(RM.onSurface)
                        .frame(width: 70, height: 70)
                        .background(RM.surface, in: Circle())
                        .overlay(Circle().stroke(RM.outline, lineWidth: 1))
                }
                .accessibilityLabel("1文字削除")
            }
        }
    }

    private func digitKey(_ value: String) -> some View {
        Button {
            append(value)
        } label: {
            Text(value)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(RM.onSurface)
                .frame(width: 70, height: 70)
                .background(RM.surface, in: Circle())
                .overlay(Circle().stroke(RM.outline, lineWidth: 1))
        }
        .accessibilityLabel(value)
    }

    private func append(_ value: String) {
        guard digits.count < maxDigits else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        digits += value
        error = nil
        guard digits.count >= 4 else { return }

        // Unlock as soon as the entered digits match, without pressing 解除.
        // The duress code may be longer than the main PIN, so check both at
        // every length before deciding a normal PIN was wrong.
        if lock.hasDuress, lock.checkDuress(digits) {
            emergencyWipe()
            return
        }

        let mainLength = lock.pinLength
        let emergencyLength = lock.duressLength

        if digits.count == mainLength,
           emergencyLength == nil || emergencyLength == mainLength,
           lock.check(digits) {
            digits = ""
            lock.recordSuccess()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            error = nil
            return
        }

        // A legacy emergency code may not have its length recorded. Keep the
        // old 8-digit fallback for those installs.
        if lock.hasDuress, emergencyLength == nil {
            if digits.count >= maxDigits { unlock() }
            return
        }

        // Count a failure only after the longest valid length. This avoids
        // cutting off a longer emergency code while still counting every full
        // PIN/emergency-code guess exactly once.
        let longest = max(mainLength, emergencyLength ?? mainLength)
        if digits.count >= longest {
            failAttempt()
        }
    }

    private func deleteDigit() {
        guard !digits.isEmpty else { return }
        digits.removeLast()
    }

    private func emergencyWipe() {
        digits = ""
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        onWipe()
    }

    private func failAttempt() {
        let shouldWipe = lock.recordFailure()
        digits = ""
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        if shouldWipe {
            onWipe()
        } else {
            error = "暗証番号が違います"
        }
    }

    private func unlock() {
        if lock.hasDuress, lock.checkDuress(digits) {
            emergencyWipe()
            return
        }
        if lock.check(digits) {
            digits = ""
            lock.recordSuccess()
            error = nil
        } else {
            failAttempt()
        }
    }
}
