import SwiftUI

/// Settings tab. Mirrors the Android screen's structure (profile, notifications,
/// security, data, app info) with iOS-native controls. Preferences that need a
/// later device increment (passcode lock, security zones) are stored now and
/// labelled honestly instead of pretending to work.
struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var lock: LockStore
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var tor: TorSession
    @AppStorage("rm.displayName") private var savedName = ""
    @AppStorage("rm.preview") private var previewInNotifications = false
    @AppStorage("rm.autoLockSeconds") private var autoLockSeconds = 30
    @AppStorage("rm.retentionDays") private var retentionDays = 30
    @AppStorage("rm.zoneWanted") private var zoneWanted = false

    @State private var showNameEdit = false
    @State private var showPolicy = false
    @State private var showPINChange = false
    @State private var showDuress = false
    @State private var confirmClearChats = false
    @State private var confirmClearFriends = false
    @State private var showZoneEditor = false
    @State private var showLocationPrimer = false
    @State private var showPrivacyTutorial = false
    @State private var zone: SecurityZone? = SecurityZoneStore.current

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Avatar(name: store.displayName)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.displayName).font(.headline)
                            Text("表示名を変更")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showNameEdit = true }

                    LabeledContent("ID", value: shortId)
                        .font(.footnote)
                } header: {
                    Text("プロフィール")
                }

                Section {
                    Toggle("通知に本文を表示", isOn: $previewInNotifications)
                    Button("通知を許可") {
                        NotificationManager.shared.requestAuthorization()
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("オフの場合は「新しいメッセージ」だけを表示します。")
                }

                Section {
                    LabeledContent("Tor", value: tor.statusText)
                    if tor.supportsTor {
                        LabeledContent("リレー", value: tor.reachable ? "接続OK" : "未接続")
                        if let lastError = tor.lastError {
                            Text(lastError)
                                .font(.caption)
                                .foregroundStyle(RM.onSurfaceVariant)
                                .lineLimit(3)
                        }
                        Button("接続を確認") { tor.checkNow() }
                    } else {
                        Text("モックビルドでは無効です（実ビルドで有効になります）")
                            .font(.caption)
                            .foregroundStyle(RM.onSurfaceVariant)
                    }
                } header: {
                    Text("ネットワーク")
                } footer: {
                    Text("メッセージと招待は .onion リレーへ Tor 経由でのみ送信されます。直接のインターネット接続は行いません。")
                }

                Section {
                    if location.hasPermission {
                        LabeledContent("位置情報の権限", value: "許可済み")
                    } else {
                        Button("位置情報を許可") { showLocationPrimer = true }
                    }
                    if let zone {
                        LabeledContent("半径", value: "\(Int(zone.radius))m")
                        LabeledContent("入室時の動作", value: zone.action.label)
                        Button("地図で変更") { showZoneEditor = true }
                        Button("プライバシーゾーンを削除", role: .destructive) {
                            SecurityZoneStore.current = nil
                            self.zone = nil
                            zoneWanted = false
                        }
                    } else {
                        if zoneWanted {
                            Text("オンボーディングで有効化しました。場所を設定してください。")
                                .font(.footnote)
                                .foregroundStyle(RM.primary)
                            Button("プライバシーゾーンを無効にする", role: .destructive) {
                                zoneWanted = false
                            }
                        } else {
                            Text("未設定")
                                .foregroundStyle(RM.onSurfaceVariant)
                        }
                        Button("地図で設定") { showZoneEditor = true }
                    }
                } header: {
                    Text("プライバシーゾーン")
                } footer: {
                    Text("たとえば「自宅で自動ロック」「職場でトーク消去」。判定は端末内で行い、位置情報をサーバーに送りません。位置情報の利用許可はこの画面で行います。")
                }

                if !store.blockedContacts.isEmpty {
                    Section("ブロックしたユーザー") {
                        ForEach(store.blockedContacts) { contact in
                            HStack(spacing: 10) {
                                Avatar(name: contact.name)
                                Text(contact.name)
                                Spacer()
                                Button("解除") {
                                    store.setBlocked(contact.id, false)
                                }
                                .font(.footnote.weight(.semibold))
                            }
                        }
                    }
                }

                Section {
                    Picker("自動ロック", selection: $autoLockSeconds) {
                        Text("オフ").tag(0)
                        Text("5秒").tag(5)
                        Text("15秒").tag(15)
                        Text("30秒").tag(30)
                        Text("1分").tag(60)
                        Text("5分").tag(300)
                    }
                    Button { showPINChange = true } label: {
                        HStack {
                            Text("パスコードを変更")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(RM.onSurface)
                    Button { lock.lock() } label: {
                        HStack {
                            Text("今すぐロック")
                            Spacer()
                            Image(systemName: "lock.fill")
                                .foregroundStyle(RM.onSurfaceVariant)
                        }
                    }
                    .foregroundStyle(RM.onSurface)
                    Button { showPrivacyTutorial = true } label: {
                        HStack {
                            Text("プライバシーのヒント")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(RM.onSurface)
                    Button { showDuress = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("緊急用パスコード")
                                Text("入力すると端末内のデータを消去")
                                    .font(.caption2)
                                    .foregroundStyle(RM.onSurfaceVariant)
                            }
                            Spacer()
                            Text(lock.hasDuress ? "設定済み" : "未設定")
                                .foregroundStyle(RM.onSurfaceVariant)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(RM.onSurface)
                } header: {
                    Text("セキュリティ")
                } footer: {
                    Text("自動ロックはバックグラウンドに移ってからの経過時間で判定します。")
                }

                Section {
                    Picker("メッセージの自動削除", selection: $retentionDays) {
                        Text("オフ").tag(0)
                        Text("7日").tag(7)
                        Text("30日").tag(30)
                        Text("90日").tag(90)
                        Text("365日").tag(365)
                    }
                    .onChange(of: retentionDays) { _, days in
                        store.purgeOldMessages(days: days)
                    }
                    Button("トークを全部消す", role: .destructive) {
                        confirmClearChats = true
                    }
                    Button("友だちを全員消す", role: .destructive) {
                        confirmClearFriends = true
                    }
                } header: {
                    Text("データ")
                } footer: {
                    Text("この端末の履歴だけを削除します。相手の端末には残ります。")
                }

                Section {
                    LabeledContent("バージョン", value: appVersion)
                    Button("プライバシーポリシー") { showPolicy = true }
                } header: {
                    Text("このアプリ")
                }

                Section {
                    Link("サポートページ", destination: SupportConfig.supportURL)
                    Link("公開プライバシーポリシー", destination: SupportConfig.privacyURL)
                    Link("利用規約", destination: SupportConfig.termsURL)
                    Link("運営に問い合わせる",
                         destination: URL(string: "mailto:\(SupportConfig.email)")!)
                } header: {
                    Text("サポート")
                } footer: {
                    Text("通報・お問い合わせ: \(SupportConfig.email)")
                }
            }
            .navigationTitle("設定")
            .onAppear { zone = SecurityZoneStore.current }
            .sheet(isPresented: $showNameEdit) {
                NameEditSheet().environmentObject(store)
            }
            .sheet(isPresented: $showPolicy) {
                PrivacySheet()
            }
            .sheet(isPresented: $showPINChange) {
                ChangePINView().environmentObject(lock)
            }
            .sheet(isPresented: $showDuress) {
                DuressView().environmentObject(lock)
            }
            .sheet(isPresented: $showLocationPrimer) {
                LocationPrimer().environmentObject(location)
            }
            .sheet(isPresented: $showPrivacyTutorial) {
                PrivacyTutorialSheet()
            }
            .sheet(isPresented: $showZoneEditor, onDismiss: {
                zone = SecurityZoneStore.current
                if zone != nil { zoneWanted = false }
            }) {
                ZoneEditorView(zone: zone).environmentObject(tor)
            }
            .confirmationDialog(
                "トークを全部消しますか？",
                isPresented: $confirmClearChats,
                titleVisibility: .visible
            ) {
                Button("全部消す", role: .destructive) { store.clearAllMessages() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この端末のメッセージ履歴を削除します。友だちは残ります。")
            }
            .confirmationDialog(
                "友だちを全員消しますか？",
                isPresented: $confirmClearFriends,
                titleVisibility: .visible
            ) {
                Button("全員消す", role: .destructive) { store.clearAllContacts() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("友だちとトーク履歴をこの端末から削除します。")
            }
        }
    }

    private var shortId: String {
        let id = store.myId
        guard id.count > 12 else { return id }
        return String(id.prefix(6)) + "…" + String(id.suffix(4))
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Display name

private struct NameEditSheet: View {
    @EnvironmentObject private var store: ChatStore
    @AppStorage("rm.displayName") private var savedName = ""
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("表示名", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("友だちに表示される名前です。")
                }
            }
            .navigationTitle("表示名を変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { name = store.displayName }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedName = trimmed
        store.updateDisplayName(trimmed)
        dismiss()
    }
}

// MARK: - Privacy

private struct PrivacySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("RichMan は、電話番号・メールアドレスを登録せず、メッセージ・画像・ファイル・通話音声を端末間でエンドツーエンド暗号化します。通信は Tor を経由します。")
                    Group {
                        Text("収集する情報").font(.headline)
                        Text("・アカウント識別子: 端末内で生成する公開鍵。電話番号・メール・広告IDは収集しません。\n・メッセージと添付: 暗号文を中継サーバーが一時的に預かり、配信確認後に削除します。\n・位置情報: プライバシーゾーンを有効化すると位置情報の利用許可を求め、許可後に端末で位置情報を取得します。取得した位置はゾーン判定にのみ使い、端末内で処理し、サーバーには保存しません。")
                        Text("保存期間").font(.headline)
                        Text("未配信の暗号文は配信確認後または7日で削除。端末内の履歴は既定30日で自動削除（変更可）。")
                        Text("端末内のデータ").font(.headline)
                        Text("履歴・写真・ファイル・鍵は端末内に暗号化して保存され、iCloud/iTunes バックアップから除外されます。設定した緊急用パスコードをロック画面で入力すると、端末内のデータ（履歴・メディア・鍵・Tor の状態）をすべて消去します（取り消し不可）。")
                        Text("第三者提供").font(.headline)
                        Text("広告・分析SDK・トラッカーは使用せず、第三者提供も行いません。新着通知は内容を含まないAPNsで送り、通知に本文・送信者名は含めません。地図タイルはリレー経由で取得し、端末から配信元へは直接接続しません。")
                        Text("安全上の限界").font(.headline)
                        Text("中継サーバーは投函メタデータを扱います（本文・位置は含みません）。本アプリは独立した暗号監査を受けていません。")
                        Text("画面録画・ミラーリング中は内容を隠します。iOS の仕様上、スクリーンショットの撮影自体は防げません。")
                        Text("お問い合わせ").font(.headline)
                        Text(SupportConfig.email)
                        Link("サポートページ", destination: SupportConfig.supportURL)
                    }
                    .font(.callout)
                }
                .padding(20)
            }
            .navigationTitle("プライバシーポリシー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

struct DuressView: View {
    @EnvironmentObject private var lock: LockStore
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var duress = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var confirmSave = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "入力すると端末内のデータをすべて消去します",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(RM.error)
                    Text("元に戻せません。通常の暗証番号とは別の番号にしてください。")
                        .font(.footnote)
                        .foregroundStyle(RM.onSurfaceVariant)                } header: {
                    Text("緊急用パスコードとは")
                }

                Section("現在の暗証番号") {
                    SecureField("現在の暗証番号", text: $current)
                        .keyboardType(.numberPad)
                }
                Section {
                    SecureField("緊急用パスコード", text: $duress)
                        .keyboardType(.numberPad)
                    SecureField("もう一度入力", text: $confirm)
                        .keyboardType(.numberPad)
                } header: {
                    Text("新しい緊急用パスコード")
                } footer: {
                    Text("通常の暗証番号と同じ桁数で設定します。ロック画面でこのパスコードを入力した瞬間に、メッセージ・写真・鍵などの端末内データを消去します。確認画面は出ません。")
                }
                if lock.hasDuress {
                    Section {
                        Button("緊急用パスコードを削除", role: .destructive) {
                            guard lock.check(current) else {
                                error = "現在の暗証番号が違います"
                                return
                            }
                            lock.removeDuress()
                            dismiss()
                        }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(RM.error)
                }
            }
            .navigationTitle("緊急用パスコード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { requestSave() }
                        .disabled(duress.count < 4)
                }
            }
            .confirmationDialog(
                "緊急用パスコードを設定しますか？",
                isPresented: $confirmSave,
                titleVisibility: .visible
            ) {
                Button("設定する", role: .destructive) { save() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("ロック画面でこのパスコードを入力すると、端末内のデータがすべて消去されます。この操作は取り消せません。")
            }
        }
    }

    private func requestSave() {
        guard lock.check(current) else {
            error = "現在の暗証番号が違います"
            return
        }
        guard duress.count >= 4, duress.count <= 8,
              duress.count == lock.pinLength,
              duress.allSatisfy(\.isNumber) else {
            error = "通常の暗証番号と同じ桁数（\(lock.pinLength)桁）で設定してください"
            return
        }
        guard duress == confirm else {
            error = "パスコードが一致しません"
            return
        }
        guard !lock.check(duress) else {
            error = "通常の暗証番号とは別の番号にしてください"
            return
        }
        error = nil
        confirmSave = true
    }

    private func save() {
        if lock.setDuress(duress) {
            dismiss()
        } else {
            error = "保存できませんでした"
        }
    }
}

private struct ChangePINView: View {
    @EnvironmentObject private var lock: LockStore
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var next = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("現在の暗証番号") {
                    SecureField("現在の暗証番号", text: $current)
                        .keyboardType(.numberPad)
                }
                Section("新しい暗証番号") {
                    SecureField("新しい暗証番号", text: $next)
                        .keyboardType(.numberPad)
                    SecureField("もう一度入力", text: $confirm)
                        .keyboardType(.numberPad)
                }
                if let error {
                    Text(error).foregroundStyle(RM.error)
                }
            }
            .navigationTitle("パスコードを変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(next.count < 4)
                }
            }
        }
    }

    private func save() {
        guard lock.check(current) else {
            error = "現在の暗証番号が違います"
            return
        }
        guard next.count >= 4, next.count <= 8,
              next.allSatisfy(\.isNumber) else {
            error = "数字4〜8桁で設定してください"
            return
        }
        guard next == confirm else {
            error = "新しい暗証番号が一致しません"
            return
        }
        if lock.setPIN(next) {
            dismiss()
        } else {
            error = "保存できませんでした"
        }
    }
}
