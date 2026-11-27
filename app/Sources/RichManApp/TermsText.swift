import Foundation

/// Full terms shown inside onboarding. Keep this in sync with
/// `site/terms.html` (the public page).
enum TermsText {
    struct Section: Identifiable {
        let id: String
        let heading: String
        let paragraphs: [String]
    }

    static let updated = "最終更新 2026-11-27"

    static let sections: [Section] = [
        Section(
            id: "1",
            heading: "1. 適用",
            paragraphs: [
                "本規約は RichMan（以下「本アプリ」）の利用条件を定めます。本アプリを利用した時点で同意したものとみなします。"
            ]
        ),
        Section(
            id: "2",
            heading: "2. 禁止する行為",
            paragraphs: [
                "嫌がらせ、脅迫、ストーカー行為、差別、わいせつ物、児童の性的搾取、違法薬物、詐欺、なりすまし、個人情報の無断公開、スパム、マルウェアの送信、本アプリや中継サーバーへの攻撃を禁止します。これらの行為は一切許容しません。"
            ]
        ),
        Section(
            id: "3",
            heading: "3. 通報・ブロック",
            paragraphs: [
                "トーク画面の「通報」は、理由と相手の公開IDだけを support@kelvins.works へ送ります。本文は送信されず、運営も復号できません。「ブロック」で相手からの受信を端末側で停止できます。",
                "通報は24時間以内に確認し、必要に応じて警告、改善、技術的に可能な範囲での配信停止を行います。緊急時は警察などの公的な窓口へ連絡してください。"
            ]
        ),
        Section(
            id: "4",
            heading: "4. データ",
            paragraphs: [
                "アカウント登録はありません。端末内のデータは設定から削除できます。緊急用パスコードを設定している場合、ロック画面で入力すると端末内データを消去できます（ローカルのみ、取り消し不可）。"
            ]
        ),
        Section(
            id: "5",
            heading: "5. 暗号化と可用性",
            paragraphs: [
                "本アプリは libsignal によるエンドツーエンド暗号化と Tor を使用します。運営は本文を復号できません。受信はアプリ起動中または iOS のバックグラウンド更新時に行われ、到着が遅れることがあります。緊急通報には使えません。独立した暗号監査は受けていません。"
            ]
        ),
        Section(
            id: "6",
            heading: "6. 免責・変更・問い合わせ",
            paragraphs: [
                "本アプリは現状有姿で提供され、特定目的への適合性や継続的な可用性を保証しません。本規約を変更する場合は本ページの更新日を改めます。",
                "support@kelvins.works ／ サポート・通報"
            ]
        ),
    ]
}
