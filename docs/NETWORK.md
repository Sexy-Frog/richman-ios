# ネットワーク層（Tor + リレー）

RichMan の全通信は **埋め込み Tor → リレーの .onion** の 1 経路のみ。
クリアネットへのフォールバックは実装していない（`SOCKS5Transport` は
SOCKS プロキシ経由でしか接続しない）。

```
SwiftUI
  └─ ChatStore ── RelayService ── RelayClient ── SOCKS5Transport ──┐
                                                                  │ 127.0.0.1:39050
  TorSession ── TorLauncher (tor_run_main, tor.xcframework) ──────┘
                                                                  │
                                                          .onion relay :80
```

## コンポーネント

| 場所 | 役割 |
| --- | --- |
| `Sources/RichManCore/SOCKS5.swift` | SOCKS5（ドメイン名 CONNECT、RFC1929 認証）＋ HTTP/1.1 クライアント。Linux/macOS/iOS 共通。 |
| `tor/` | `tor.xcframework` を SwiftPM から使う薄いラッパー（`TorLauncher` / `TorConfig`）。 |
| `app/Sources/RichManApp/TorSession.swift` | Tor 起動、ブートストラップ判定（`/healthz`）、フェーズ公開。 |
| `app/Sources/RichManApp/TorSession.swift` + `ChatStore.attachRelay` | Tor 準備完了〜フォアグラウンドの間だけ送受信ループを回す。 |
| `app/Sources/RichManApp/MapProxy.swift` | 127.0.0.1 のループバック HTTP。MapLibre のタイル/グリフ/スプライトを `/v1/map/*` 経由で Tor に流す。 |
| `app/Sources/RichManApp/Resources/map_style_ja.json` | `__MAP_BASE__` 入りスタイル（日本語ラベル）。プロキシ起動時にループバック URL へ置換。 |
| `app/Sources/RichManApp/LocalStore.swift` | 連絡先・履歴・グループ・場所・メールボックスの封緘保存（Keychain 鍵）。 |

- SOCKS のユーザー名は「default」。Tor の `IsolateSOCKSAuth` により
  メールボックス単位でサーキットを分離できる（将来 `box` をユーザー名にする）。
- 応答は `Content-Length` で打ち切り、上限 16 MiB。無限/巨大応答は破棄。
- 1 リクエスト = 1 TCP 接続（プールなし）。リレー側の接続再利用で
  別メールボックスがリンクされないようにするため。

## ビルド（実リレー有効）

リポジトリは公開のため、オニオンアドレスは**ソースに置かない**。
ビルド時に環境変数 `RM_RELAY_HOST` で注入する。

```bash
cd tor && bash scripts/fetch-tor.sh   # Vendor/tor.xcframework（150MB、非コミット）
cd ../app
RM_RELAY_HOST=<onion> xcodegen generate --spec project-crypto.yml
xcodebuild -project RichManCrypto.xcodeproj -scheme RichManCryptoApp \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  LIBRARY_SEARCH_PATHS="<libsignal_ffi.a のあるディレクトリ>" \
  OTHER_LDFLAGS="-lsignal_ffi" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 build
```

シミュレータ用 FFI は `aarch64-apple-ios-sim` のみビルドするため、
`generic/platform=iOS Simulator` でも x86_64 を除外する（Intel Mac の
シミュレータは非対応。実機 arm64 と Apple Silicon シミュレータは可）。

CI（`iOS Crypto`）では `secrets.RM_RELAY_HOST` を xcodegen に渡している。
未設定のビルドでは設定画面に「リレー未設定」と表示し、招待は
オフライン用（リレーを使わない）にフォールバックする。

## 招待フロー（docs/PROTOCOL.md §2 と同一）

1. 招待者が 32B の受信メールボックス `box` を新規生成（1 招待 = 1 ボックス）。
2. `buildBundle(displayName:box:)` で prekey bundle を作る。
3. QR 内だけの AES-256-GCM 鍵 `k` で bundle を封緘（`nonce‖ct‖tag`）。
4. `POST /v1/invite` → 使い捨て token `t`。
5. QR `{v,id,n,tag,box,k,t}` を相手が読み取る。
6. 相手は `/v1/invite/fetch` → `InviteSealer.open` → `id/tag/box` 照合 →
   `startSession`（X3DH + PQXDH）→ 自分の受信 `box` を生成。
7. 最初のメッセージは招待者の `box` に届き、`rb`（相手の受信 box）で
   以後の返信先が確定する。招待者は未使用の招待 box をポーリングして
   最初のメッセージで連絡先を作る（`ChatStore.pendingBoxes`）。

## 画像・ファイル・位置・グループ

- **画像/ファイル**: 送信時に AES-256-GCM（blob ごとに新しい鍵）で暗号化し、
  `/v1/blob` に置いて `img`/`file` ペイロードで鍵と nonce を送る。受信側は
  blob を取得して復号し、`MediaStore`（10MB 上限・完全保護）に保存する。
  blob id は base64url 64 文字に制限（経路注入防止）。
- **位置**: チャットの「現在地」から **その場限り** の `loc_once` を送る。
  バックグラウンド共有は無い。受信した位置は `ChatStore.places` に入り、
  マップの友だちピンとして表示される（`loc_stop` で消える）。
- **グループ**: 作成時に `group_invite` をメンバーへ 1:1 送信し、本文は
  `group_msg` を各メンバーへファンアウトする（フルメッシュ、ハブ不要）。
  `group_add` / `group_remove` / `group_leave` でメンバーを同期。
  グループ画像/ファイルはまだ未対応。
- **地図**: Tor 接続後、`MapProxy` が `http://127.0.0.1:<port>/style.json` を
  配信し、MapLibre はループバックだけを見る。実際の取得は RelayClient が
  SOCKS 経由で `/v1/map/*` を叩く。ATS は `NSAllowsLocalNetworking` のみ許可。
  Tor 未接続時はプレースホルダー（リリース）／直接 CDN（DEBUG のみ）。
- **通話**: `call_offer` / `call_answer` / `call_end` と ADPCM 音声
  (`call_audio`) を同じ 1:1 暗号化経路で送る。音声は 16 kHz（相手が旧版なら
  8 kHz）・300 ms チャンク・IMA ADPCM。通話中は相手メールボックスを
  long-poll（wait 15s）して遅延を抑える。Tor の RTT が大きいため通話品質は
  ネットワーク次第。`AVAudioEngine` + `AVAudioConverter` で 16 kHz に変換する。

## E2E（CI）

`iOS E2E` ワークフローが **2 台の iOS Simulator** で実リレーに対して
「招待 → 双方向テキスト → 画像 → 位置 → グループ → Tor 地図（スタイル+タイル取得）」
を実行する。アプリは `-rm.e2eRole host|join` で起動し、結果を
`Documents/e2e.json` に書く（`E2E.swift`, DEBUG のみ）。Apple Developer
アカウントは不要。

## 端末内の保存

`LocalStore` が Application Support の `state.bin` に
`[1][nonce12][ciphertext][tag16]`（AES-256-GCM）で保存する。鍵は Keychain の
`WhenUnlockedThisDeviceOnly`。デモ/スクリーンショットビルド（`-rm.demo`）は
読み書きしない。緊急消去は state・メディア・libsignal ストア・両方の鍵を破棄。

## 既知の制約 / 次の増分

- **実機での疎通は未検証**。CI はビルドまで。実機で
  「招待作成 → 別端末で読み取り → 双方向メッセージ」を確認する必要がある。
- 通話は Tor の遅延により品質が不安定（300ms チャンク、ジッタで破棄）。
- グループ画像/ファイル、グループの未読バッジは未対応。
- 地図プロキシは 1 リクエスト 1 SOCKS 接続。初回表示は Tor の遅延を伴う。
- Tor 起動はプロセス常駐（Tor C API に停止関数がない）。Android と同じ。
- App Store 審査では Tor 内蔵の説明が必要（DESIGN §9 の運用方針を参照）。
