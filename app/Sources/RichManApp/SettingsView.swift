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
    @AppStorage("rm.autoLockSeconds") private var autoLockSeconds = 0
    @AppStorage("rm.retentionDays") private var retentionDays = 30
    @AppStorage("rm.shareLocation") private var shareLocation = true

    @State private var showNameEdit = false
    @State private var showPolicy = false
    @State private var showPINChange = false
    @State private var showDuress = false
    @State private var confirmClearChats = false
    @State private var confirmClearFriends = false
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
                    Toggle("友達に位置情報を共有", isOn: $shareLocation)
                    if location.hasPermission {
                        LabeledContent("位置情報の権限", value: "許可済み")
                    } else {
                        Button("位置情報を許可") { location.requestPermission() }
                    }
                } header: {
                    Text("位置情報")
                } footer: {
                    Text("共有はTor・リレー実装後に有効になります。現在は地図の現在地表示のみです。")
                }

                Section {
                    if let zone {
                        LabeledContent("半径", value: "\(Int(zone.radius))m")
                        LabeledContent("入室時の動作", value: zone.action.label)
                        Button("セキュリティゾーンを削除", role: .destructive) {
                            SecurityZoneStore.current = nil
                            self.zone = nil
                        }
                    } else {
                        Text("未設定（オンボーディングで設定できます）")
                            .foregroundStyle(RM.onSurfaceVariant)
                    }
                } header: {
                    Text("セキュリティゾーン")
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
                    Button { showDuress = true } label: {
                        HStack {
                            Text("緊急消去コード")
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
        store.displayName = trimmed
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
                        Text("・アカウント識別子: 端末内で生成する公開鍵。電話番号・メール・広告IDは収集しません。\n・メッセージと添付: 暗号文を中継サーバーが一時的に預かり、配信確認後に削除します。\n・位置情報: 友達と共有している間だけ取得し、相手の端末に暗号化して送ります。サーバーには保存しません。")
                        Text("保存期間").font(.headline)
                        Text("未配信の暗号文は配信確認後または7日で削除。端末内の履歴は既定30日で自動削除（変更可）。")
                        Text("第三者提供").font(.headline)
                        Text("広告・分析SDK・トラッカー・FCM/APNs は使用せず、第三者提供も行いません。地図タイルはリレー経由で取得し、端末から配信元へは直接接続しません。")
                        Text("安全上の限界").font(.headline)
                        Text("中継サーバーは投函メタデータを扱います（本文・位置は含みません）。本アプリは独立した暗号監査を受けていません。")
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

private struct DuressView: View {
    @EnvironmentObject private var lock: LockStore
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var duress = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("現在の暗証番号") {
                    SecureField("現在の暗証番号", text: $current)
                        .keyboardType(.numberPad)
                }
                Section {
                    SecureField("緊急消去コード", text: $duress)
                        .keyboardType(.numberPad)
                    SecureField("もう一度入力", text: $confirm)
                        .keyboardType(.numberPad)
                } header: {
                    Text("新しい緊急消去コード")
                } footer: {
                    Text("ロック画面でこのコードを入力すると、端末内のデータを消去します。通常の暗証番号とは別の番号にしてください。")
                }
                if lock.hasDuress {
                    Section {
                        Button("緊急消去コードを削除", role: .destructive) {
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
            .navigationTitle("緊急消去コード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(duress.count < 4)
                }
            }
        }
    }

    private func save() {
        guard lock.check(current) else {
            error = "現在の暗証番号が違います"
            return
        }
        guard duress.count >= 4, duress.allSatisfy(\.isNumber) else {
            error = "数字4桁以上で設定してください"
            return
        }
        guard duress == confirm else {
            error = "コードが一致しません"
            return
        }
        guard !lock.check(duress) else {
            error = "通常の暗証番号とは別の番号にしてください"
            return
        }
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
        guard next.count >= 4, next.allSatisfy(\.isNumber) else {
            error = "数字4桁以上で設定してください"
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
