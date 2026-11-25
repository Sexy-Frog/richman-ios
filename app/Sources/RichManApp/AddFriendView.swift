import SwiftUI

/// Friend-add entry point: show my one-time invite, or scan a peer's. The QR
/// render / camera scan land in a later increment; for now the invite payload
/// is produced through `CryptoProvider` (mock in Simulator) and shown as text.
struct AddFriendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var inviteText: String = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("自分の招待") {
                    if inviteText.isEmpty {
                        Button("招待コードを作成") { makeInvite() }
                    } else {
                        Text(inviteText)
                            .font(.footnote.monospaced()).textSelection(.enabled)
                        Text("相手にこのQR/コードを見せて読み取ってもらいます（QR表示は実装予定）。")
                            .font(.caption).foregroundStyle(RM.onSurfaceVariant)
                    }
                }
                Section("相手を読み取る") {
                    Label("QRコードを読み取る", systemImage: "qrcode.viewfinder")
                        .foregroundStyle(RM.onSurfaceVariant)
                    Text("カメラでのスキャンは実装予定です。")
                        .font(.caption).foregroundStyle(RM.onSurfaceVariant)
                }
                if let error {
                    Text(error).foregroundStyle(RM.error)
                }
            }
            .navigationTitle("友だちを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func makeInvite() {
        do {
            let data = try model.crypto.buildInviteBundle(displayName: model.displayName)
            inviteText = String(decoding: data, as: UTF8.self)
        } catch {
            self.error = "招待の作成に失敗しました: \(error)"
        }
    }
}
