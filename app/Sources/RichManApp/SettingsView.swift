import SwiftUI

/// Settings tab. Mirrors the Android screen's structure (profile, notifications,
/// security, data, app info) with iOS-native controls. Preferences that need a
/// later device increment (passcode lock, security zones) are stored now and
/// labelled honestly instead of pretending to work.
struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @AppStorage("rm.displayName") private var savedName = ""
    @AppStorage("rm.preview") private var previewInNotifications = false
    @AppStorage("rm.autoLockSeconds") private var autoLockSeconds = 0

    @State private var showNameEdit = false
    @State private var showPolicy = false
    @State private var confirmClearChats = false
    @State private var confirmClearFriends = false

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
                } header: {
                    Text("通知")
                } footer: {
                    Text("オフの場合は「新しいメッセージ」だけを表示します。")
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
                    NavigationLink("パスコード") {
                        PlaceholderScreen(
                            title: "パスコード",
                            message: "Keychain 保存とロック画面は次の移植で入ります。"
                        )
                    }
                } header: {
                    Text("セキュリティ")
                } footer: {
                    Text("自動ロックの値は保存されます。実際のロック画面は次の移植で有効になります。")
                }

                Section {
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
            .sheet(isPresented: $showNameEdit) {
                NameEditSheet().environmentObject(store)
            }
            .sheet(isPresented: $showPolicy) {
                PrivacySheet()
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

private struct PlaceholderScreen: View {
    let title: String
    let message: String

    var body: some View {
        EmptyState(icon: "hammer", title: title, message: message)
            .navigationTitle(title)
    }
}
