import SwiftUI

/// Shared privacy-tutorial cards. Shown inline in first-launch onboarding and
/// re-openable from Settings.
struct PrivacyTutorialCards: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            card(
                "lock.fill",
                "会話は端末間で暗号化",
                "メッセージ・画像・ファイル・通話は libsignal で暗号化され、リレーにも内容は見えません。"
            )
            card(
                "eye.slash.fill",
                "追跡しません",
                "電話番号も連絡先のアップロードも不要。位置情報をバックグラウンドで取得することはありません。"
            )
            card(
                "timer",
                "消えるメッセージ",
                "トークごとに自動削除までの時間を設定できます。グローバルな保持期間も設定で変更できます。"
            )
            card(
                "rectangle.on.rectangle.slash",
                "画面のプライバシー",
                "アプリ切替や画面収録では内容を隠します。通知本文の表示もオフにできます。"
            )
            card(
                "location.circle.fill",
                "プライバシーゾーン",
                "たとえば「自宅に着いたら自動ロック」「職場ではトークを消去」「実家ではロック」。場所に応じて保護を切り替えられます。判定は端末内で行い、位置情報をサーバーに送りません。"
            )
        }
    }

    private func card(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(RM.primary)
                .frame(width: 32, height: 32)
                .background(RM.primary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(RM.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RM.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Settings entry: read the privacy tutorial again.
struct PrivacyTutorialSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("プライバシーを強化するために")
                        .font(.title2.weight(.bold))
                    Text("RichMan は最初から暗号化と追跡拒否で動きます。次の設定でさらに強化できます。")
                        .font(.subheadline)
                        .foregroundStyle(RM.onSurfaceVariant)
                    PrivacyTutorialCards()
                    Text("プライバシーゾーンは「設定 → プライバシーゾーン」からいつでも変更できます。")
                        .font(.caption)
                        .foregroundStyle(RM.onSurfaceVariant)
                }
                .padding(18)
            }
            .navigationTitle("プライバシーのヒント")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
