import SwiftUI
import CoreLocation

/// First launch: a one-screen-at-a-time intro, then a guided setup
/// (display name → privacy zone → PIN). The privacy zone comes before the PIN
/// so the location permission has a concrete, user-chosen purpose.
struct OnboardingView: View {
    @AppStorage("rm.onboarded") private var onboarded = false
    @AppStorage("rm.displayName") private var savedName = ""
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var lock: LockStore
    @EnvironmentObject private var tor: TorSession
    @EnvironmentObject private var location: LocationProvider

    private enum Step: Equatable { case intro, name, zone, pin }

    @State private var step: Step = {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "rm.onboardingStep") {
        case "name": return .name
        case "zone": return .zone
        case "pin": return .pin
        default: return .intro
        }
        #else
        return .intro
        #endif
    }()
    @State private var introPage = 0
    @State private var name = ""
    @State private var error: String?

    @State private var zoneCenter = CLLocationCoordinate2D(
        latitude: 35.6812, longitude: 139.7671
    )
    @State private var zoneRadius: Double = 300
    @State private var zoneAction: SecurityZone.Action = .lock
    @State private var useZone = false
    @State private var showLocationPrimer = false
    @State private var recenterToken = 0
    @State private var pendingCenterOnMe = false

    @State private var pinEntry = ""
    @State private var pinFirst = ""
    @State private var pinConfirming = false

    private static let introPages: [(icon: String, title: String, text: String)] = [
        (
            "lock.shield.fill",
            "RichMan へようこそ",
            "広告も追跡もない、プライバシー重視のメッセンジャーです。"
        ),
        (
            "lock.fill",
            "会話は端末間で暗号化",
            "メッセージ・画像・ファイル・通話は libsignal で暗号化。リレーにも内容は見えません。"
        ),
        (
            "eye.slash.fill",
            "追跡しません",
            "電話番号も連絡先のアップロードも不要。位置情報をバックグラウンドで取得しません。"
        ),
        (
            "location.circle.fill",
            "プライバシーゾーン",
            "自宅など決めた場所に入ると自動でロック。位置情報はこの判定と、あなたが送るときだけ使います。"
        ),
    ]

    var body: some View {
        Group {
            if step == .intro {
                introStep
            } else {
                setupStep
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RM.background)
        .sheet(isPresented: $showLocationPrimer) {
            LocationPrimer().environmentObject(location)
        }
        .onChange(of: location.location?.timestamp) { _, _ in
            guard pendingCenterOnMe, let fix = location.location else { return }
            pendingCenterOnMe = false
            zoneCenter = fix.coordinate
            recenterToken += 1
        }
    }

    // MARK: intro

    private var introStep: some View {
        VStack(spacing: 14) {
            TabView(selection: $introPage) {
                ForEach(Array(Self.introPages.enumerated()), id: \.offset) { index, page in
                    VStack(spacing: 18) {
                        Spacer(minLength: 0)
                        Image(systemName: page.icon)
                            .font(.system(size: 64))
                            .foregroundStyle(RM.primary)
                        Text(page.title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(page.text)
                            .font(.subheadline)
                            .foregroundStyle(RM.onSurfaceVariant)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 380)

            Button(introPage == Self.introPages.count - 1 ? "さあ始めよう" : "次へ") {
                if introPage == Self.introPages.count - 1 {
                    step = .name
                } else {
                    withAnimation { introPage += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(RM.primary)
            .controlSize(.large)

            Button("スキップ") { step = .name }
                .font(.footnote)
                .foregroundStyle(RM.onSurfaceVariant)
        }
        .padding(24)
    }

    // MARK: setup

    private var setupStep: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(RM.primary)
                switch step {
                case .name: nameStep
                case .zone: zoneStep
                case .pin: pinStep
                case .intro: EmptyView()
                }
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(RM.error)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var nameStep: some View {
        VStack(spacing: 14) {
            stepCaption("1 / 3")
            Text("表示名を決めましょう").font(.title2.weight(.bold))
            Text("友だちに表示される名前です。あとから設定で変更できます。")
                .font(.subheadline)
                .foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)
            TextField("表示名", text: $name)
                .padding()
                .background(RM.surface, in: RoundedRectangle(cornerRadius: 12))
            Button("次へ") { continueFromName() }
                .buttonStyle(.borderedProminent)
                .tint(RM.primary)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var zoneStep: some View {
        VStack(spacing: 10) {
            stepCaption("2 / 3")
            Text("プライバシーゾーンを設定").font(.title2.weight(.bold))
            Text("自宅など決めた場所に入ると、選んだ動作を自動で実行します。")
                .font(.subheadline)
                .foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)

            ZStack {
                ZonePickerMap(
                    center: $zoneCenter,
                    styleURL: tor.mapStyleURL ?? MapConfig.styleURL,
                    recenter: recenterToken
                )
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(RM.primary)
            }

            Button {
                centerOnCurrentLocation()
            } label: {
                Label("現在地を中心にする", systemImage: "location.fill")
                    .font(.footnote.weight(.semibold))
            }

            Text("位置情報は、このゾーンの判定と、あなたが送るときだけ使います。バックグラウンドでは取得しません。")
                .font(.caption2)
                .foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)

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

            Button("このゾーンを設定") {
                useZone = true
                step = .pin
            }
            .buttonStyle(.borderedProminent)
            .tint(RM.primary)

            Button("あとで設定する") {
                useZone = false
                step = .pin
            }
            .font(.footnote)
        }
    }

    private var pinStep: some View {
        VStack(spacing: 12) {
            stepCaption("3 / 3")
            Text(pinConfirming ? "もう一度入力" : "暗証番号を設定")
                .font(.title2.weight(.bold))
            Text(pinConfirming
                 ? "確認のため同じ4桁を入力してください。"
                 : "アプリのロック解除に使います。4桁の数字。")
                .font(.subheadline)
                .foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pinEntry.count ? RM.primary : RM.outline.opacity(0.4))
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.vertical, 8)

            pinKeypad
        }
    }

    private var pinKeypad: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3),
            spacing: 14
        ) {
            ForEach(1...9, id: \.self) { digit in
                pinKey(digit)
            }
            Color.clear.frame(width: 60, height: 60)
            pinKey(0)
            Button {
                if !pinEntry.isEmpty { pinEntry.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(.title3)
                    .foregroundStyle(RM.onSurface)
                    .frame(width: 60, height: 60)
            }
        }
        .padding(.horizontal, 24)
    }

    private func pinKey(_ digit: Int) -> some View {
        Button { appendPin(digit) } label: {
            Text("\(digit)")
                .font(.title2.weight(.medium))
                .foregroundStyle(RM.onSurface)
                .frame(width: 60, height: 60)
                .background(RM.surface, in: Circle())
        }
    }

    private func stepCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(RM.onSurfaceVariant)
    }

    // MARK: actions

    private func continueFromName() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "表示名を入力してください"
            return
        }
        error = nil
        step = .zone
    }

    private func centerOnCurrentLocation() {
        guard location.hasPermission else {
            showLocationPrimer = true
            return
        }
        if let fix = location.location {
            zoneCenter = fix.coordinate
            recenterToken += 1
        } else {
            pendingCenterOnMe = true
            location.startIfAuthorized()
        }
    }

    private func appendPin(_ digit: Int) {
        guard pinEntry.count < 4 else { return }
        pinEntry.append(String(digit))
        guard pinEntry.count == 4 else { return }

        if pinConfirming {
            if pinEntry == pinFirst {
                finish()
            } else {
                error = "暗証番号が一致しません。もう一度入力してください。"
                pinEntry = ""
                pinFirst = ""
                pinConfirming = false
            }
        } else {
            pinFirst = pinEntry
            pinEntry = ""
            pinConfirming = true
            error = nil
        }
    }

    private func finish() {
        error = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            error = "表示名を入力してください"
            step = .name
            return
        }
        guard lock.setPIN(pinFirst) else {
            error = "暗証番号を保存できませんでした。もう一度お試しください。"
            pinEntry = ""
            pinFirst = ""
            pinConfirming = false
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
