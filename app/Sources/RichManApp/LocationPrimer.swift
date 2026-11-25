import SwiftUI

/// Permission primer shown before the system prompt. The map is no longer a
/// permanent tab, so the app explains the concrete value first (meetups,
/// shared positions, security zones) and is explicit about the limits.
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
                        "プライバシーゾーンで自動ロック",
                        "自宅など決めた場所に入ると、自動でロックできます。位置情報はこの判定に使います。"
                    )
                    benefit(
                        "figure.wave",
                        "待ち合わせがスムーズ",
                        "現在地を友だちに送ったり、届いた位置を地図で確認できます。"
                    )
                    benefit(
                        "hand.raised.fill",
                        "共有は操作したときだけ",
                        "送信する位置情報は暗号化されます。バックグラウンドで取得したり、常時共有することはありません。"
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
