import SwiftUI
import RichManCore

/// Friend-add: show my invite code, or paste a peer's to add them. The QR render
/// + camera scan land next; for now the invite is produced via the CryptoProvider
/// (mock in Simulator) and exchanged as text so the flow is testable.
struct AddFriendView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var myInvite = ""
    @State private var scanned = ""
    @State private var info: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("自分の招待コード") {
                    if myInvite.isEmpty {
                        Button("招待コードを作成") { makeInvite() }
                    } else {
                        Text(myInvite).font(.footnote.monospaced()).textSelection(.enabled)
                        Text("相手にこのコード（将来はQR）を渡して読み取ってもらいます。")
                            .font(.caption).foregroundStyle(RM.onSurfaceVariant)
                    }
                }
                Section("相手を追加") {
                    TextField("招待コードを貼り付け", text: $scanned, axis: .vertical)
                    Button("追加") { add() }
                        .disabled(scanned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("カメラでのQRスキャンは実装予定です。")
                        .font(.caption).foregroundStyle(RM.onSurfaceVariant)
                }
                if let info { Text(info).foregroundStyle(RM.primary) }
                if let error { Text(error).foregroundStyle(RM.error) }
            }
            .navigationTitle("友だちを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } }
            }
        }
    }

    private func makeInvite() {
        do { myInvite = try store.makeInvite() }
        catch { self.error = "招待の作成に失敗しました: \(error)" }
    }

    private func add() {
        error = nil; info = nil
        do {
            let c = try store.addFriend(inviteText: scanned)
            info = "\(c.name) を追加しました。"
            scanned = ""
        } catch let e as InviteError {
            error = message(for: e)
        } catch {
            self.error = "追加に失敗しました: \(error)"
        }
    }

    private func message(for e: InviteError) -> String {
        switch e {
        case .malformed:           return "招待コードを読み取れませんでした。"
        case .unsupportedVersion:  return "未対応の招待コードです。"
        case .selfAdd:             return "自分自身は追加できません。"
        case .mismatchedIdentity, .mismatchedRouting, .mismatchedMailbox:
            return "招待コードが一致しません。"
        }
    }
}
