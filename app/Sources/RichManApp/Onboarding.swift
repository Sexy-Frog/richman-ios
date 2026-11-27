import SwiftUI
import CoreLocation

private struct TermsBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// First launch: one idea per screen, Signal-style. Every screen keeps its
/// primary action pinned to the bottom as a full-width button; secondary
/// choices and policy links sit just above it.
struct OnboardingView: View {
    @AppStorage("rm.onboarded") private var onboarded = false
    @AppStorage("rm.displayName") private var savedName = ""
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var lock: LockStore
    @EnvironmentObject private var location: LocationProvider

    private enum Step: Equatable { case intro, name, zone, terms, pin, notifications }

    @State private var step: Step = {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "rm.onboardingStep") {
        case "name": return .name
        case "zone": return .zone
        case "terms": return .terms
        case "pin": return .pin
        case "notifications": return .notifications
        default: return .intro
        }
        #else
        return .intro
        #endif
    }()
    @State private var introPage = 0
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var error: String?

    @State private var pinEntry = ""
    @State private var pinFirst = ""
    @State private var pinConfirming = false
    @State private var termsViewportHeight: CGFloat = 0
    @State private var termsFooterHeight: CGFloat = 0
    @State private var readTerms = false

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
            "自宅に着いたら自動ロック、職場では履歴を消去。場所に応じて保護を切り替えられます。"
        ),
    ]

    var body: some View {
        Group {
            switch step {
            case .intro: introStep
            case .name: nameStep
            case .zone: zoneStep
            case .terms: termsStep
            case .pin: pinStep
            case .notifications: notificationsStep
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RM.background)
    }

    // MARK: intro

    private var introStep: some View {
        let page = Self.introPages[min(introPage, Self.introPages.count - 1)]
        return screen(title: page.title, message: page.text) {
            art(page.icon, height: 280)
                .padding(.top, 6)
            Spacer(minLength: 0)
        } footer: {
            HStack(spacing: 7) {
                ForEach(0..<Self.introPages.count, id: \.self) { index in
                    Circle()
                        .fill(index == introPage ? RM.primary : RM.outline)
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 4)

            policyLinks

            primaryButton(introPage == Self.introPages.count - 1 ? "続ける" : "次へ") {
                advanceIntro()
            }
            .accessibilityIdentifier("introNext")
        }
    }

    private func advanceIntro() {
        if introPage >= Self.introPages.count - 1 {
            step = .name
        } else {
            introPage += 1
        }
    }

    // MARK: name

    private var nameStep: some View {
        screen(
            title: "表示名を設定",
            message: "友だちに表示される名前です。あとから設定で変更できます。"
        ) {
            art("person.crop.circle", height: 180)
                .padding(.top, 8)
            TextField("表示名", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($nameFocused)
                .onSubmit { continueFromName() }
                .font(.body)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(RM.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(RM.outline, lineWidth: 1)
                )
                .padding(.top, 6)
            errorText
        } footer: {
            primaryButton("次へ") { continueFromName() }
        }
        .onAppear { nameFocused = true }
    }

    // MARK: zone

    private var zoneStep: some View {
        screen(
            title: "プライバシーゾーン",
            message: "決めた場所に入ったときに、アプリを自動で守る機能です。"
        ) {
            art("location.viewfinder", height: 190)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 14) {
                example(
                    "house.fill",
                    "自宅に着いたら自動ロック",
                    "ソファに置き忘れても、家族や来客に中身を見られません。"
                )
                example(
                    "building.2.fill",
                    "職場ではトークを消去",
                    "同僚の目に触れる履歴を残さずに済みます。"
                )
                example(
                    "person.2.fill",
                    "実家・取引先ではロック",
                    "人に端末を渡す場面でも、画面を開かれません。"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RM.surface, in: RoundedRectangle(cornerRadius: 14))

            Text("ゾーン判定は端末内で行い、位置情報をサーバーに送りません。")
                .font(.caption)
                .foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)
            errorText
        } footer: {
            primaryButton("プライバシーゾーンを有効にする") { enableZone() }
            secondaryButton("後で設定する") { skipZone() }
        }
    }

    // MARK: terms

    private var termsStep: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("利用規約への同意")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("内容を最後まで確認すると同意できます。")
                    .font(.subheadline)
                    .foregroundStyle(RM.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("RichMan 利用規約")
                        .font(.headline)
                    Text(TermsText.updated)
                        .font(.caption2)
                        .foregroundStyle(RM.onSurfaceVariant)

                    ForEach(TermsText.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.heading)
                                .font(.subheadline.weight(.semibold))
                            ForEach(section.paragraphs, id: \.self) { paragraph in
                                Text(paragraph)
                                    .font(.footnote)
                                    .foregroundStyle(RM.onSurfaceVariant)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Text("「同意して続ける」を押すと、利用規約とプライバシーポリシーに同意したものとみなされます。")
                        .font(.caption2)
                        .foregroundStyle(RM.onSurfaceVariant)
                        .padding(.top, 4)

                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: TermsBottomKey.self,
                                    value: proxy.frame(in: .named("termsScroll")).maxY
                                )
                            }
                        )
                }
                .padding(20)
                .background(RM.surface, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            .coordinateSpace(name: "termsScroll")
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { termsViewportHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in
                            termsViewportHeight = height
                        }
                }
            )
            .onPreferenceChange(TermsBottomKey.self) { bottom in
                guard termsViewportHeight > 0 else { return }
                let visibleBottom = max(0, termsViewportHeight - termsFooterHeight)
                if bottom <= visibleBottom + 16 {
                    readTerms = true
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if !readTerms {
                        Text("最後までスクロールすると同意できます")
                            .font(.caption2)
                            .foregroundStyle(RM.onSurfaceVariant)
                    }
                    primaryButton("同意して続ける") { step = .pin }
                        .disabled(!readTerms)
                        .opacity(readTerms ? 1 : 0.45)
                    Link("プライバシーポリシー", destination: SupportConfig.privacyURL)
                        .font(.caption2)
                        .tint(RM.onSurfaceVariant)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .background(RM.background)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { termsFooterHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, height in
                                termsFooterHeight = height
                            }
                    }
                )
            }
        }
    }

    // MARK: pin

    private var pinStep: some View {
        screen(
            title: pinConfirming ? "もう一度入力" : "暗証番号を設定",
            message: pinConfirming
                ? "確認のため同じ4桁を入力してください。"
                : "アプリのロック解除に使います。4桁の数字。"
        ) {
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pinEntry.count ? RM.primary : RM.outline)
                        .frame(width: 15, height: 15)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 6)

            pinKeypad
                .padding(.top, 4)
            errorText
            Spacer(minLength: 0)
        } footer: {
            EmptyView()
        }
    }

    private var pinKeypad: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3),
            spacing: 16
        ) {
            ForEach(1...9, id: \.self) { digit in
                pinKey(digit)
            }
            Color.clear.frame(width: 64, height: 64)
            pinKey(0)
            Button {
                if !pinEntry.isEmpty { pinEntry.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(.title3)
                    .foregroundStyle(RM.onSurface)
                    .frame(width: 64, height: 64)
            }
        }
        .padding(.horizontal, 24)
    }

    private func pinKey(_ digit: Int) -> some View {
        Button { appendPin(digit) } label: {
            Text("\(digit)")
                .font(.title2.weight(.medium))
                .foregroundStyle(RM.onSurface)
                .frame(width: 64, height: 64)
                .background(RM.surface, in: Circle())
                .overlay(Circle().stroke(RM.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: notifications

    private var notificationsStep: some View {
        screen(
            title: "メッセージの取得",
            message: "通知権限は、メッセージの着信や会話の更新をお知らせします。"
        ) {
            art("bell.badge.fill", height: 280)
                .padding(.top, 10)
            Text("通知の内容は端末内で決まり、リレーや Apple にメッセージ本文は送られません。")
                .font(.caption)
                .foregroundStyle(RM.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        } footer: {
            primaryButton("パーミッションを有効化") {
                finish(requestNotifications: true)
            }
            secondaryButton("後で") {
                finish(requestNotifications: false)
            }
        }
    }

    // MARK: shared layout

    /// Title + message + content, with the action area pinned above the home
    /// indicator. Matches Signal's onboarding rhythm: one thought per screen.
    private func screen<Content: View, Footer: View>(
        title: String,
        message: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(RM.onBackground)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(RM.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
                content()
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                footer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(RM.background)
        }
    }

    /// Large soft panel standing in for Signal's illustration.
    private func art(_ symbol: String, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(RM.primary.opacity(0.08))
            Circle()
                .fill(RM.primary.opacity(0.10))
                .frame(width: height * 0.58, height: height * 0.58)
            Image(systemName: symbol)
                .font(.system(size: height * 0.32, weight: .regular))
                .foregroundStyle(RM.primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(RM.onPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RM.primary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(RM.onSurfaceVariant)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
        }
        .buttonStyle(.plain)
    }

    private var policyLinks: some View {
        HStack(spacing: 6) {
            Link("利用規約", destination: SupportConfig.termsURL)
            Text("・").foregroundStyle(RM.onSurfaceVariant)
            Link("プライバシーポリシー", destination: SupportConfig.privacyURL)
        }
        .font(.caption2)
        .tint(RM.onSurfaceVariant)
    }

    @ViewBuilder
    private var errorText: some View {
        if let error {
            Text(error)
                .font(.footnote)
                .foregroundStyle(RM.error)
                .multilineTextAlignment(.center)
        }
    }

    private func example(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(RM.primary)
                .frame(width: 28, height: 28)
                .background(RM.primary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.footnote.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(RM.onSurfaceVariant)
            }
        }
    }

    // MARK: actions

    private func continueFromName() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "表示名を入力してください"
            return
        }
        error = nil
        nameFocused = false
        step = .zone
    }

    /// Opt in to the zone and ask iOS for location permission right here (the
    /// system prompt). The actual place/radius/action are chosen later in
    /// Settings.
    private func enableZone() {
        UserDefaults.standard.set(true, forKey: "rm.zoneWanted")
        if location.authorization == .notDetermined {
            location.requestPermission()
        } else {
            location.startIfAuthorized()
        }
        step = .terms
    }

    private func skipZone() {
        UserDefaults.standard.set(false, forKey: "rm.zoneWanted")
        step = .terms
    }

    private func appendPin(_ digit: Int) {
        guard pinEntry.count < 4 else { return }
        pinEntry.append(String(digit))
        guard pinEntry.count == 4 else { return }

        if pinConfirming {
            if pinEntry == pinFirst {
                error = nil
                step = .notifications
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

    private func finish(requestNotifications: Bool) {
        error = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            error = "表示名を入力してください"
            step = .name
            return
        }
        guard !pinFirst.isEmpty, lock.setPIN(pinFirst) else {
            error = "暗証番号を保存できませんでした。もう一度お試しください。"
            pinEntry = ""
            pinFirst = ""
            pinConfirming = false
            step = .pin
            return
        }
        savedName = trimmed
        store.displayName = trimmed
        onboarded = true
        if requestNotifications {
            NotificationManager.shared.requestAuthorization()
        }
    }
}
