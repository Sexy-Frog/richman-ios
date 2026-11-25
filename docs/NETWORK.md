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
  OTHER_LDFLAGS="-lsignal_ffi" build
```

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

## 既知の制約 / 次の増分

- **実機での疎通は未検証**。CI はビルドまで。実機で
  「招待作成 → 別端末で読み取り → 双方向メッセージ」を確認する必要がある。
- 連絡先・メッセージ・pending box はまだメモリのみ（DB 永続化は未実装）。
  アプリ再起動で招待 box のポーリングは失われる。
- 画像/ファイル/位置/グループ/通話はまだ暗号化リレー経路に載っていない
  （テキストと既読・削除のみ）。
- 地図タイルは DEBUG のみ直接取得。リリースは Tor 経由 `/v1/map/*` へ
  切り替えるまでプレースホルダー。
- Tor 起動はプロセス常駐（Tor C API に停止関数がない）。Android と同じ。
- App Store 審査では Tor 内蔵の説明が必要（DESIGN §9 の運用方針を参照）。
