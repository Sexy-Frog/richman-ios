# RichMan iOS — 設計書 / 進め方

最終更新: 2026-11-25

Android 版 RichMan（`D:\LINE_pt2\android`、稼働中 1.0.21）とバイト単位で相互運用する
ネイティブ iOS クライアントを、**Mac を持たずに** GitHub Actions（macOS ランナー）で
ビルドして完成させるための設計と手順。

---

## 1. 目的・前提

- **目的**: iOS 版 RichMan を作り、Android ⇄ iPhone で同一リレー越しにチャットできるようにする。
- **互換性が最優先**: プロトコルは Android と完全一致（Wire v2 封筒、libsignal X3DH+PQXDH/
  Kyber1024 + Double Ratchet、`/v1` オニオンリレーAPI、招待バンドルJSON、`[type][ciphertext]`
  フレーミング）。権威仕様は `docs/PROTOCOL.md`、実装の真実は Android の `net/`・`crypto/`。
- **匿名性**: クリアネット禁止（Tor のみ）、端末内は AES-GCM 封緘、緊急消去で鍵破棄。
- **UIは Android 版を踏襲**: ハブ（トーク/友だち/設定）、Signal-blue（`#3A76F0`）。

### 制約

| 制約 | 影響 |
| --- | --- |
| 開発機は **Windows**（Mac/Xcode 無し） | iOS のコンパイル/署名は **macOS CI でしか**できない |
| ローカル検証は **Docker** のみ | Foundation だけの純ロジックしか手元で `swift test` できない |
| libsignal に公式 SwiftPM 配布が無い | FFI を **ソースから**ビルド（Apple専用、submodule @ v0.86.5） |
| `.ipa` 実機導入には **Apple Developer**（$99/年） | 署名ビルドの前提。取得手続き中 |

---

## 2. 全体アーキテクチャ（レイヤ）

```
┌──────────────────────────────────────────────┐
│  app/  SwiftUI アプリ（画面・状態）           │  iOS Simulator でビルド検証（署名不要）
│    RootView / Chat / Friends / Settings …     │
│    AppModel ── CryptoProvider ───┐            │
└──────────────────────────────────┼───────────┘
                                   │ refine
┌──────────────────────────────────▼───────────┐
│  RichManCore  （純 Foundation・Docker 検証）  │  ★手元で swift test 可能
│    Wire v2 / Base64URL / Identifiers          │
│    Messages / Invite / MediaManifest          │
│    RelayClient + RelayTransport(protocol)      │
│    MessagePipeline + **CryptoEngine(protocol)**│
└──────────────┬────────────────────┬───────────┘
               │ implements         │ implements
┌──────────────▼──────────┐ ┌───────▼───────────┐
│ RichManCrypto (Apple)   │ │ Tor transport     │  macOS CI でのみビルド
│  libsignal 0.86.5 FFI    │ │  RelayTransport    │
│  KeyManager/SignalStore  │ │  (Tor.framework)   │
└──────────────────────────┘ └────────────────────┘
```

**設計の要 = `CryptoEngine` 境界**。UI もメッセージパイプラインも、暗号を
`CryptoEngine`（myId/encrypt/decrypt/peekSenderId）越しにしか触らない。これにより:

- 実装は `RichManCrypto`（libsignal）だが、**モック実装**を挿せば `RichManCore` は
  Docker（Linux/Swift）で、`app` は iOS Simulator で、**FFI も Apple アカウントも無しに
  コンパイル検証**できる。
- Tor も `RelayTransport` 境界で後差し。コアはトランスポート非依存。

---

## 3. モジュール構成

| モジュール | 置き場 | ビルド環境 | 役割 |
| --- | --- | --- | --- |
| **RichManCore** | `ios/` (ルート) | Linux/Docker・CI | 相互運用の純ロジック（封筒・メッセージ・招待・リレー・パイプライン・CryptoEngine境界） |
| **RichManCrypto** | `ios/crypto/` | macOS CI のみ | libsignal FFI（鍵・セッション・暗号化）+ SealedBox(AES-GCM) |
| **app** | `ios/app/` | macOS CI (Simulator) | SwiftUI アプリ。XcodeGen で `.xcodeproj` 生成 |
| Tor transport | 予定 | macOS/iOS | `RelayTransport` を Tor SOCKS 上で実装 |

---

## 4. ビルド＆検証戦略（4段）

1. **コア（無料・高速）**: `RichManCore` を Docker `swift:5.10` と CI の Linux コンテナで
   `swift test`。手元で即検証。← **今ここが常時グリーン（41テスト）**
2. **暗号（macOS, 課金対象だが公開リポで無料）**: `crypto` ジョブで submodule から
   libsignal FFI をソースビルド → `swift test`（2者ハンドシェイク往復・SealedBox）。
3. **アプリUI（macOS, 署名/アカウント不要）**: `app` ジョブで `xcodegen generate` →
   `xcodebuild -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO`。UI/Swift の全コンパイルを検証。
4. **署名 .ipa（Apple Developer 必要）**: 別ワークフローで `xcodebuild archive` →
   `-exportArchive`。証明書(.p12)/プロファイルは GitHub Secrets。TestFlight 配布も同経路。

> ポイント: **1→3 はアカウント無しで回る**。実機 `.ipa`（4）だけが Apple Developer 待ち。
> だから「アプリを書く→Simulatorビルドで赤を潰す」を先に回し切れる。

### CI トリガ方針（macOS 分の節約）

- core: すべての push / PR。
- crypto・app（macOS）: **main への push と手動実行のみ**（PR では回さない）。公開リポなので
  macOS 分は無料だが、無駄打ちは避ける。同一 ref の新 run は旧 run を自動キャンセル。

---

## 5. 相互運用の不変条件（壊したら Android と通信不能）

- **Wire v2 封筒**: 4096B 固定、ヘッダ `[ver=2][kind][len16]`、以降ペイロード＋ランダムpad。
  送信者情報は封筒に入れない。返信箱 `rb` は暗号化ペイロード内。
- **kind=1 ペイロード** = `[libsignal type byte][ciphertext]`。
- **招待**: QR `{v:1,id,n,tag,box,k,t}` / リレー `{e}`=b64url(nonce12‖GCM ct) /
  バンドル `{v,id,n,tag,box,reg,spk{i,p,s},opk{i,p},kpk{i,p,s}}`。
- **メッセージ種別**（`t`）と鍵名は `docs/PROTOCOL.md §6` と Android に一致（text/read/ttl/img/
  file/del/profile/loc_*/group_*/call_*）。`loc_req`（×loc_request）。
- **libsignal 0.86.x** を Android と揃える（現状 0.86.5）。

これらは `RichManCore` のテストで固定済み（Android形状のJSONをデコード／封筒往復）。

---

## 6. ロードマップ（フェーズと現在地）

| # | フェーズ | 状態 |
| --- | --- | --- |
| 0 | リポジトリ公開・CI 骨組み（core緑/crypto/app ジョブ） | ✅ 公開済み `Sexy-Frog/richman-ios` |
| 1 | **RichManCore**（封筒・メッセージ・招待・manifest・パイプライン・CryptoEngine） | ✅ 41テスト緑（Docker） |
| 2 | **RichManCrypto** を macOS CI でビルド＆ハンドシェイク検証 | ✅ X3DH/PQXDH・SealedBox・招待封緘テスト緑 |
| 3 | **app** を Simulator ビルドで緑に（UI骨組み→実画面へ） | ✅ 全画面移植済み |
| 4 | Tor トランスポート（`RelayTransport` 実装） | ✅ SOCKS5クライアント＋埋め込みTor（`tor/`）ビルド緑 |
| 5 | 実データ配線（リレー送受信ループ＋crypto＋ローカルDB封緘） | ✅ 招待・送受信・画像/ファイル・位置・グループ・封緘保存（実機検証待ち） |
| 6 | 全画面移植（下記§7） | ✅（§7 参照） |
| 7 | 署名 `.ipa` ワークフロー → 実機確認 | ⬜（Apple Developer 待ち） |
| 8 | 機能拡張（地図/ファイル/通話/緊急消去/セキュリティゾーン）→ TestFlight | ✅ 実装済み・実機検証待ち |

**進め方の原則**: フェーズ2→3を緑にして「土台が確実にコンパイルする」状態を作ってから、
§7 の画面を増やす。各追加は「書く→CIでビルド→ログで赤を潰す」を1サイクルとする。

---

## 7. 移植する画面（Android → SwiftUI）

| 画面 | 内容 | 現状 |
| --- | --- | --- |
| オンボーディング | 1画面ずつの紹介 → 表示名 → プライバシーゾーン（任意）→ 暗証番号（カスタムキーパッド） | ✅ |
| ハブ | マップ / トーク / 友だち / 設定 のタブ | ✅ |
| トーク一覧 | 会話リスト・未読・長押しプレビュー | ✅ |
| チャット(1:1) | テキスト/画像/ファイル/リプライ/既読/消えるタイマー/削除/通話ボタン | ✅（テキストはTor経由・実機未検証） |
| 友だち | 一覧・QR招待・QR読み取り | ✅（実リレー招待はTor接続時） |
| グループ | 作成・招待・グループ情報（ハブ方式） | ✅（メンバー管理込み） |
| 設定 | プロフィール・パスコード・自動ロック・セキュリティゾーン・データ削除 | ✅ |
| 通話オーバーレイ | 発着信・通話中（ADPCM 16kHz） | ✅（ローカル検証） |
| 地図 | 位置共有・位置確認（MapLibre iOS） | ✅ タブ廃止・オンデマンド表示（Tor ループバックプロキシ経由） |
| 初回チュートリアル | プライバシー強化の説明 → プライバシーゾーン設定 | ✅ |
| 公式アカウント | ローカル専用アナウンス（自動返信なし） | ✅ |

ネットワーク層（Tor・招待・送受信・既知の制約）は [`NETWORK.md`](NETWORK.md) を参照。

---

## 8. 未決事項・TODO

- [ ] **Apple Developer** 登録完了 → Team ID / 証明書 / プロファイルを Secrets に。
  - [ ] **登録前に**アカウント種別（Organization 推奨）と**名義**を決める（§9 運営者プライバシー：
        署名CN/販売者名が露出する）。配布は TestFlight / ad-hoc に限定するか要検討。
- [ ] **バンドルID** 確定（仮 `works.kelvins.richman`、運営者を示唆しない中立な値に）。
- [ ] crypto FFI ビルドが CI で通るか（初回ログ対応：protoc/cmake 等）。
- [ ] 端末内DB：SQLite + SealedBox、鍵は Keychain/Secure Enclave（iOS BFU 相当）。
- [ ] Tor 組み込み方式（Tor.framework vs Arti）。
- [ ] 画像/ファイルの blob 経路（12MiB 制限、`SafeImage` 相当の防御的デコード）。
- [ ] 通話の AudioUnit 実装（ADPCM、16kHz ネゴシエーション、ジッタバッファ）。

---

## 9. 運営者（オペレータ）プライバシー

利用者の匿名性に加え、**このアプリ/リレーを運営する側（オペレータ）の身元も露出しない**ことを
設計目標とする。実装・運用のあらゆる判断でこれを基準にする。

### コード・リポジトリ
- サーバのオニオンアドレス/ホストは**ソースに持たせない**（実行時注入）。✅ 現状コアに無し。
- コミット作者は noreply（`Sexy-Frog@users.noreply.github.com`）。実メール/実名を履歴に残さない。✅
- GitHub は擬名アカウント（Sexy-Frog）。README/doc からライブサービス（kelvins.works）への
  紐付けを除去済み。✅ 公開リポは説明・topics を空にして検索ヒットを下げる。✅
- **CI（GitHubランナー）でビルド**＝バイナリに運営者のローカルPCのパス/ユーザ名が焼き込まれない
  （`/Users/runner/...` になる）。ローカルMacビルドより露出が少ない副次効果。✅

### 署名・Apple Developer（最重要の露出点）
- `.ipa` には署名証明書の CN（＝Apple アカウントの名義）と Team ID が埋め込まれ、
  **`.ipa` を入手した誰でも読める**。App Store 公開は「販売者名」も公開される。
- 対策:
  - できれば **Organization アカウント＋中立的な名義**で登録し個人名を出さない（法人/団体と
    D-U-N-S 番号が必要）。
  - **公開 App Store を避け、TestFlight か 直接インストール（ad-hoc）**に配布を限定して露出範囲を絞る。
  - Individual アカウントだと署名 CN＝個人名になるので、`.ipa` は信頼できる相手にのみ渡す。
  - Apple 自身は実身元を必ず把握する（避けられない第三者信頼点）。ここでの目的は「公開/第三者
    からの秘匿」。
  - → **登録前にアカウント種別と名義を決める**（§8 TODO）。

### インフラ・配布
- リレーはオニオンのみ（クリアネット無し）、リクエストログ無し（PROTOCOL.md §4）。
- デプロイ鍵/サーバ資格情報はリポジトリに入れない。✅（`server/` 配下は `ios/` 外）。
- ドメイン/ホスティング/支払いは匿名で（運営者の運用判断領域）。

### バイナリ・メタデータ
- Info.plist/バンドルに運営者 PII を入れない。バンドルIDも中立に（仮 `works.kelvins.richman`）。
- クラッシュレポート/解析 SDK は入れない（運営者にもデータを送らない）。

## 10. App Store 公開対応（配布目標）

配布目標は **App Store 公開**。審査（App Review）要件を最初から設計に織り込む。
§9 の「公開 App Store を避ける」はこの目標により**上書き**（運営者は販売者名の公開を受容済み）。

### 審査で必須・要注意
- **UGC モデレーション（Guideline 1.2／最重要）**: ユーザー間メッセージがある以上、**ブロック**・
  **通報（report）**・不適切利用者の排除手段、連絡先の提示が**必須**。E2E で内容は見えなくても、
  **ブロック/通報の仕組みは実装必須**（未実装だとほぼ確実にリジェクト）。
- **アカウント削除（Guideline 5.1.1(v)）**: アプリ内でアカウント削除を提供（既存の「アカウント削除」を維持）。
- **暗号輸出コンプライアンス**: `ITSAppUsesNonExemptEncryption = YES`（本アプリは強い暗号を使う）。
  輸出規制の自己分類（年次レポート/該当国申告）を別途対応（5D992.c 免除の確認）。
- **プライバシー**: プライバシーポリシー URL 必須、プライバシー"栄養ラベル"（収集データ申告。
  本アプリは最小収集の想定）。
- **審査用デモ**: 招待制 P2P なので、**レビュアーが試せる手順/デモ経路**を用意（2アカウントの
  招待手順書、またはレビュー用モード）。これが無いと「動作確認できず」でリジェクトされやすい。
- **年齢レーティング**: メッセージングは 17+ 相当になりやすい。
- **プッシュ通知/バックグラウンド配信**: iOS は背面でソケットを維持できない。実用的な新着通知には
  **APNs プッシュ**がほぼ必須（＝プッシュ送信サーバ＋Apple がトークンを見る、という匿名性との
  トレードオフ）。採らない場合は「前面時のみ受信」になる。**要決定**。
- **Tor/オニオンのまま審査**: オニオンのみ接続・"匿名化"を前面に出すと審査リスク。接続方式・
  説明文の見せ方を要検討（§3/4 の Tor 方針と App Store のバランス）。**要決定**。
- 私的 API 不使用・標準フレームワークのみ・クラッシュで落ちない等の基本要件。

### 要決定（アーキテクチャに影響）
1. **バックグラウンド配信**: APNs プッシュを使うか（新着通知の実用性↑／メタデータは Apple 経由）、
   前面のみにするか。
2. **Tor の扱い**: そのままオニオン直結で審査に挑むか、審査用に見せ方/接続方式を調整するか。
3. ブロック/通報の実装方式（E2E 前提の report 設計）。

## 11. 参照

- `README.md` … リポジトリ概要
- `CI_SETUP.md` … GitHub Actions / submodule / 公開・コストの手順
- `crypto/INTEGRATION.md` … libsignal FFI の配線
- `docs/PROTOCOL.md`（Android 側）… 権威プロトコル仕様
