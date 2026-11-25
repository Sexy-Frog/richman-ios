import SwiftUI

/// Report a user (App Store UGC Guideline 1.2). Because chats are end-to-end
/// encrypted, the operator can't read content; reporting records the reason
/// locally and offers to block the user. (A device build may also forward an
/// abuse signal to the operator's contact — kept minimal/metadata-light.)
struct ReportSheet: View {
    let contact: Contact
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    private let reasons = ["スパム", "いやがらせ・不適切な内容", "なりすまし", "その他"]
    @State private var reason = "スパム"
    @State private var alsoBlock = true
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                Section("理由") {
                    Picker("理由", selection: $reason) {
                        ForEach(reasons, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                Section {
                    Toggle("このユーザーをブロックする", isOn: $alsoBlock)
                }
                Section {
                    Button("通報する", role: .destructive) { submit() }
                } footer: {
                    Text("通報内容は端末に記録されます。トークは端末間で暗号化されているため、運営は中身を見られません。")
                }
            }
            .navigationTitle("\(contact.name) を通報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() } }
            }
            .alert("通報を受け付けました", isPresented: $done) {
                Button("OK") { dismiss() }
            } message: {
                Text(alsoBlock ? "このユーザーをブロックしました。" : "ご報告ありがとうございます。")
            }
        }
    }

    private func submit() {
        if alsoBlock { store.setBlocked(contact.id, true) }
        done = true
    }
}
