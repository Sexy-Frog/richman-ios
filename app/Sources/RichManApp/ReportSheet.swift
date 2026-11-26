import SwiftUI
import UIKit

/// Report a user (App Store UGC Guideline 1.2). Chats are end-to-end
/// encrypted, so the operator cannot read message content. The report records
/// the reason locally, optionally blocks the user, and opens a prefilled
/// `mailto:` to the monitored support mailbox (reason + peer public id only).
struct ReportSheet: View {
    let contact: Contact
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    private let reasons = ["スパム", "いやがらせ・不適切な内容", "なりすまし", "その他"]
    @State private var reason = "スパム"
    @State private var alsoBlock = true
    @State private var done = false
    @State private var copied = false

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
                    Button("運営に通報する", role: .destructive) { submit() }
                    Button {
                        UIPasteboard.general.string = reportText
                        copied = true
                    } label: {
                        Label("通報内容をコピー", systemImage: "doc.on.doc")
                    }
                    Link("サポートページ", destination: SupportConfig.supportURL)
                } footer: {
                    Text("通報はメールアプリで \(SupportConfig.email) 宛に開きます。暗号化されたメッセージ本文は送らず、理由と相手の公開IDだけを送ります。")
                }
                if copied {
                    Text("通報内容をコピーしました。")
                        .foregroundStyle(RM.primary)
                }
            }
            .navigationTitle("\(contact.name) を通報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() } }
            }
            .alert("通報を受け付けました", isPresented: $done) {
                Button("通報内容をコピー") {
                    UIPasteboard.general.string = reportText
                }
                Button("閉じる", role: .cancel) { dismiss() }
            } message: {
                Text(alsoBlock
                     ? "このユーザーをブロックしました。メールアプリが開かない場合は、\(SupportConfig.email) までご連絡ください。"
                     : "メールアプリが開かない場合は、\(SupportConfig.email) までご連絡ください。")
            }
        }
    }

    private var reportText: String {
        """
        通報理由: \(reason)
        相手の公開ID: \(contact.id)
        アプリ: RichMan iOS
        日時: \(Date().formatted())
        送信先: \(SupportConfig.email)
        """
    }

    private func submit() {
        if alsoBlock { store.setBlocked(contact.id, true) }
        if let url = SupportConfig.reportMailURL(reason: reason, peerId: contact.id) {
            UIApplication.shared.open(url)
        }
        done = true
    }
}
