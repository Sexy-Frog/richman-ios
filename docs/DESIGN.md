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
| 2 | **RichManCrypto** を macOS CI でビルド＆ハンドシェイク検証 | 🟡 初回CI 実行中（FFIビルド） |
| 3 | **app** を Simulator ビルドで緑に（UI骨組み→実画面へ） | 🟡 骨組み作成済み・初回ビルド待ち |
| 4 | Tor トランスポート（`RelayTransport` 実装） | ⬜ |
| 5 | 実データ配線（リレー送受信ループ＋crypto＋ローカルDB封緘） | ⬜ |
| 6 | 全画面移植（下記§7） | ⬜（骨組みのみ） |
| 7 | 署名 `.ipa` ワークフロー → 実機確認 | ⬜（Apple Developer 待ち） |
| 8 | 機能拡張（地図/ファイル/通話/緊急消去/セキュリティゾーン）→ TestFlight | ⬜ |

**進め方の原則**: フェーズ2→3を緑にして「土台が確実にコンパイルする」状態を作ってから、
§7 の画面を増やす。各追加は「書く→CIでビルド→ログで赤を潰す」を1サイクルとする。

---

## 7. 移植する画面（Android → SwiftUI）

| 画面 | 内容 | 現状 |
| --- | --- | --- |
| オンボーディング | パスコード設定 → 表示名 → セキュリティゾーン設定（任意・入室時動作選択） | ⬜ |
| ハブ | トーク / 友だち / 設定 のタブ | 🟡 骨組み |
| トーク一覧 | 会話リスト・未読・長押しプレビュー | 🟡 骨組み |
| チャット(1:1) | テキスト/画像/ファイル/リプライ/既読/消えるタイマー/削除/通話ボタン | 🟡 骨組み（ローカルエコー） |
| 友だち | 一覧・QR招待・QR読み取り | 🟡 骨組み（招待コード生成のみ） |
| グループ | 作成・招待・グループ情報（ハブ方式） | ⬜ |
| 設定 | プロフィール・パスコード・自動ロック・セキュリティゾーン・データ削除 | 🟡 骨組み |
| 通話オーバーレイ | 発着信・通話中（ADPCM 16kHz） | ⬜ |
| 地図 | 位置共有・/locate（MapLibre iOS） | ⬜ |
| 公式アカウント | ローカル専用アナウンス（自動返信なし） | ⬜ |

---

## 8. 未決事項・TODO

- [ ] **Apple Developer** 登録完了 → Team ID / 証明書 / プロファイルを Secrets に。
- [ ] **バンドルID** 確定（仮 `works.kelvins.richman`）。
- [ ] crypto FFI ビルドが CI で通るか（初回ログ対応：protoc/cmake 等）。
- [ ] 端末内DB：SQLite + SealedBox、鍵は Keychain/Secure Enclave（iOS BFU 相当）。
- [ ] Tor 組み込み方式（Tor.framework vs Arti）。
- [ ] 画像/ファイルの blob 経路（12MiB 制限、`SafeImage` 相当の防御的デコード）。
- [ ] 通話の AudioUnit 実装（ADPCM、16kHz ネゴシエーション、ジッタバッファ）。

---

## 9. 参照

- `README.md` … リポジトリ概要
- `CI_SETUP.md` … GitHub Actions / submodule / 公開・コストの手順
- `crypto/INTEGRATION.md` … libsignal FFI の配線
- `docs/PROTOCOL.md`（Android 側）… 権威プロトコル仕様
