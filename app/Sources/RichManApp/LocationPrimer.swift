import SwiftUI

/// Permission primer shown before the system prompt. The map is no longer a
/// permanent tab, so the app explains the concrete value first (security zones)
/// and is explicit about the limits.
struct LocationPrimer: View {
    @EnvironmentObject private var location: LocationProvider
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Spacer()
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(RM.primary)
                        Spacer()
                    }
                    Text("位置情報を使うと")
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .center)

                    benefit(
                        "lock.shield.fill",
                        "場所に応じて自動で保護",
                        "自宅に着いたら自動ロック、職場では履歴を消去。ゾーン判定は端末内だけで、位置情報をサーバーに送りません。"
                    )
                    benefit(
                        "map.fill",
                        "ゾーンを地図で設定",
                        "プライバシーゾーンの中心と半径を地図で決められます。"
                    )
                    benefit(
                        "hand.raised.fill",
                        "必要なときだけ",
                        "位置情報はプライバシーゾーンの判定にのみ使い、端末内で処理します。サーバーには送りません。"
                    )

                    Button {
                        location.requestPermission()
                        dismiss()
                    } label: {
                        Text(location.hasPermission ? "位置情報は許可済み" : "位置情報を許可")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RM.primary)
                    .disabled(location.hasPermission)

                    Button("あとで") { dismiss() }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(RM.onSurfaceVariant)

                    Text("許可しなくても、メッセージやQR招待は利用できます。")
                        .font(.caption)
                        .foregroundStyle(RM.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func benefit(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(RM.primary)
                .frame(width: 30, height: 30)
                .background(RM.primary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(RM.onSurfaceVariant)
            }
        }
    }
}
