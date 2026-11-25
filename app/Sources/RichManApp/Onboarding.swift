import SwiftUI
import CoreLocation

/// First-launch setup: PIN → display name → optional security zone.
struct OnboardingView: View {
    @AppStorage("rm.onboarded") private var onboarded = false
    @AppStorage("rm.displayName") private var savedName = ""
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var lock: LockStore
    @EnvironmentObject private var tor: TorSession

    private enum Step { case pin, name, zone }
    @State private var step: Step = .pin
    @State private var pin = ""
    @State private var pinConfirm = ""
    @State private var name = ""
    @State private var error: String?

    @State private var zoneCenter = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)
    @State private var zoneRadius: Double = 300
    @State private var zoneAction: SecurityZone.Action = .lock
    @State private var useZone = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56)).foregroundStyle(RM.primary)
            switch step {
            case .pin:  pinStep
            case .name: nameStep
            case .zone: zoneStep
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
            Button("次へ") { step = .zone }
                .buttonStyle(.borderedProminent).tint(RM.primary)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var zoneStep: some View {
        VStack(spacing: 12) {
            Text("セキュリティゾーン（任意）").font(.title2.weight(.bold))
            Text("指定した場所に入ると、選んだ動作を実行します。")
                .font(.subheadline)
                .foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)

            ZStack {
                ZonePickerMap(
                    center: $zoneCenter,
                    styleURL: tor.mapStyleURL ?? MapConfig.styleURL
                )
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(RM.primary)
            }

            HStack(spacing: 10) {
                Text("半径").font(.caption)
                Slider(value: $zoneRadius, in: 100...1000, step: 50)
                Text("\(Int(zoneRadius))m")
                    .font(.caption.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }

            Picker("入室時の動作", selection: $zoneAction) {
                ForEach(SecurityZone.Action.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
            .pickerStyle(.menu)

            Button("このゾーンを設定してはじめる") {
                useZone = true
                finish()
            }
            .buttonStyle(.borderedProminent)
            .tint(RM.primary)

            Button("設定せずにはじめる") {
                useZone = false
                finish()
            }
            .font(.footnote)
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
        if useZone {
            SecurityZoneStore.current = SecurityZone(
                latitude: zoneCenter.latitude,
                longitude: zoneCenter.longitude,
                radius: zoneRadius,
                action: zoneAction
            )
        }
        savedName = trimmed
        store.displayName = trimmed
        onboarded = true
        NotificationManager.shared.requestAuthorization()
    }
}
