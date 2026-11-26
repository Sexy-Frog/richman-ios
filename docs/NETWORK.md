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
- **位置**: チャットで `/locate`（`/loc`・`/where`・`/位置`）と入力すると
  `loc_req` を送り、相手は共有トグルON＋現在地があれば `loc_once` を返す。
  返答が届くと **地図が自動で開く**。バックグラウンド共有は無い。
  受信した位置は `ChatStore.places` に入り、地図のピンとして表示される
  （`loc_stop` で消える）。地図はタブではなく、この返答・受信位置のタップ・
  プライバシーゾーン編集からオンデマンドで開く。
- **グループ**: 作成時に `group_invite` をメンバーへ 1:1 送信し、本文は
  `group_msg` を各メンバーへファンアウトする（フルメッシュ、ハブ不要）。
  `group_add` / `group_remove` / `group_leave` でメンバーを同期。
  グループ画像/ファイルはまだ未対応。
- **地図**: タブには置かない（Android と同じ）。`/locate` の返答・受信位置の
  タップ・プライバシーゾーン編集でシート表示する。Tor 接続後、`MapProxy` が
  `http://127.0.0.1:<port>/style.json` を配信し、MapLibre はループバックだけを
  見る。実際の取得は RelayClient が SOCKS 経由で `/v1/map/*` を叩く。ATS は
  `NSAllowsLocalNetworking` のみ許可。Tor 未接続時はプレースホルダー（リリース）
  ／直接 CDN（DEBUG のみ）。DEBUG は Android 版と同じ配色の
  `map_style_direct.json`（Android の `map_style.json` から生成、日本語ラベル・
  OpenFreeMap の公開ソース）を使うため、Simulator でも色合いが一致する。
- **位置情報の許可**: 初回起動はスキップ不可の 1 画面ずつ紹介（暗号化・
  追跡拒否・プライバシーゾーン）→「さあ始めよう」→ **表示名 →
  プライバシーゾーン → 暗証番号** の順でチュートリアル形式に設定する。
  ゾーン画面は説明だけにし、「有効にする」か「後で設定する」の二択にする。
  「有効にする」を押すと位置情報のシステム許可ダイアログを出し、場所・半径・
  動作はあとから設定で選ぶ（`rm.zoneWanted` で未設定を案内）。位置情報は
  端末内のゾーン判定に使い、送信時は暗号化されること、バックグラウンド取得が
  ないことを UI と `NSLocationWhenInUseUsageDescription` の両方で明示する。
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

CI ではホスト Mac の Tor（`127.0.0.1:9050`）を共有し、アプリは
`-rm.tor off -rm.socksPort 9050` でそれを使う。埋め込み Tor の起動は
`iOS Tor` の macOS スモークテスト（SOCKS リスナー）で担保する。
地図プロキシも同じ SOCKS を通るため、Tor 経由のタイル取得まで検証される。

**2026-11-25 に E2E 成功**（`iOS E2E` run 45675466309, 24m39s）:
host/join 両方 `crypto=real` で
`text / image / place / group / map` がすべて true。

E2E で判明した重要事項:
- Tor の CLI は `--SocksPort 9050` の 2 argv 形式のみ（`--SocksPort=9050` は
  "Unknown option" で起動失敗）。`IsolateSOCKSAuth` は SocksPort のフラグ。
- `CODE_SIGNING_ALLOWED=NO` の Simulator ビルドは Keychain が
  `errSecMissingEntitlement (-34018)` になる。E2E は ad-hoc 署名
  (`CODE_SIGN_IDENTITY=-`) でビルドする。
- libsignal のセッションはスレッドセーフではない。送信・受信・通話が同じ
  ピアのラチェットを同時に触るとロストするため、`KeyManager` を
  再帰ロックで直列化し、`ChatStore` は RelayService を 1 個だけ使う。
- グリフ URL はスペースを含む（`fonts/Noto Sans Regular/...`）。プロキシ側で
  percent-encode しないと HTTP リクエスト行が壊れる。

### 緊急用パスコード

設定 → セキュリティ → 緊急用パスコード。現在の PIN で認可し、通常の PIN とは
別のコードだけを設定できる。設定時に「入力すると全データを消去する」警告と
確認ダイアログを出す。ロック画面で一致した瞬間に、メッセージ・写真・
libsignal ストア・Keychain（PIN/デュレス/状態鍵）・ゾーン・設定を消去する。
サーバーには何も送らない。審査向けの説明と試験手順は `docs/APP_REVIEW.md`。

## 端末内の保存

`LocalStore` が Application Support の `state.bin` に
`[1][nonce12][ciphertext][tag16]`（AES-256-GCM）で保存する。鍵は Keychain の
`WhenUnlockedThisDeviceOnly`。デモ/スクリーンショットビルド（`-rm.demo`）は
読み書きしない。緊急消去は state・メディア・libsignal ストア・両方の鍵を破棄。

## 既知の制約 / 次の増分

- **実機**での疎通は未検証（Simulator 2 台の E2E は成功）。署名 `.ipa` が
  用意でき次第、実機で同じシナリオを確認する。
- 通話音声は ADPCM + AVAudioEngine + リレー信号まで実装済みだが、CI では
  マイクが使えないため音声そのものの E2E は未実施。Tor の遅延で品質は
  ネットワーク次第（300ms チャンク、バックログは破棄）。
- グループ画像/ファイル、グループの未読バッジは未対応。
- 地図プロキシは 1 リクエスト 1 SOCKS 接続。初回表示は Tor の遅延を伴う。
- Tor 起動はプロセス常駐（Tor C API に停止関数がない）。Android と同じ。
- App Store 審査では Tor 内蔵の説明が必要（DESIGN §9 の運用方針を参照）。
