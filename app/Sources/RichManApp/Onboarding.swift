import SwiftUI

/// First-launch setup: set a passcode, then a display name. Mirrors the Android
/// onboarding order (PIN → name → [security zone, later]).
///
/// NOTE: the passcode is only collected here; secure at-rest storage (Keychain /
/// Secure Enclave, and the lock-screen gate) is a later device-only increment —
/// we deliberately do NOT persist the PIN in UserDefaults.
struct OnboardingView: View {
    @AppStorage("rm.onboarded") private var onboarded = false
    @AppStorage("rm.displayName") private var savedName = ""
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var lock: LockStore

    private enum Step { case pin, name }
    @State private var step: Step = .pin
    @State private var pin = ""
    @State private var pinConfirm = ""
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56)).foregroundStyle(RM.primary)
            switch step {
            case .pin:  pinStep
            case .name: nameStep
            }
            if let error { Text(error).font(.footnote).foregroundStyle(RM.error) }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RM.background)
    }

    private var pinStep: some View {
        VStack(spacing: 16) {
            Text("パスコードを設定").font(.title2.weight(.bold))
            Text("アプリのロック解除に使います。").font(.subheadline).foregroundStyle(RM.onSurfaceVariant)
            SecureField("4桁以上の数字", text: $pin)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .padding().background(RM.surface, in: RoundedRectangle(cornerRadius: 12))
            SecureField("もう一度入力", text: $pinConfirm)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .padding().background(RM.surface, in: RoundedRectangle(cornerRadius: 12))
            Button("次へ") { advanceFromPin() }
                .buttonStyle(.borderedProminent).tint(RM.primary)
                .disabled(pin.count < 4)
        }
    }

    private var nameStep: some View {
        VStack(spacing: 16) {
            Text("表示名").font(.title2.weight(.bold))
            Text("友だちに表示される名前です。").font(.subheadline).foregroundStyle(RM.onSurfaceVariant)
            TextField("表示名", text: $name)
                .padding().background(RM.surface, in: RoundedRectangle(cornerRadius: 12))
            Button("はじめる") { finish() }
                .buttonStyle(.borderedProminent).tint(RM.primary)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func advanceFromPin() {
        guard pin.allSatisfy(\.isNumber), pin.count >= 4 else { error = "数字4桁以上で設定してください"; return }
        guard pin == pinConfirm else { error = "パスコードが一致しません"; return }
        error = nil
        step = .name
    }

    private func finish() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard lock.setPIN(pin) else {
            error = "パスコードを保存できませんでした。もう一度お試しください。"
            return
        }
        savedName = trimmed
        store.displayName = trimmed
        onboarded = true
    }
}
