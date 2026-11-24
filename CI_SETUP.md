# iOS CI セットアップ（GitHub Actions / macOS ランナー）

このリポジトリ（`ios/` を単独のGitHubリポジトリとして push する想定）を GitHub Actions
でビルドするための手順。ワークフローは `.github/workflows/ci.yml`。

- **core ジョブ** … Linux の Swift コンテナで `RichManCore`（純JSONの相互運用コア）を
  build/test。無料分で回る。ローカルの Docker `swift:5.10` 検証と同一。
- **crypto ジョブ** … **macOS ランナー**で `RichManCrypto`（libsignal 0.86.5 を
  **ソースから FFI ビルド**）を build/test。ここが libsignal/PQXDH が正しく通るかを
  確かめる本命。macOS 分は課金対象なので、`pull_request` では回さず、`main` への
  push と Actions タブからの手動実行（workflow_dispatch）だけで回す設定にしてある。

## 1. libsignal を submodule として登録（必須・1回だけ）

crypto ジョブは checkout 時に `submodules: recursive` で libsignal を取得する。そのため
`.gitmodules` にエントリをコミットしておく必要がある（これが無いと CI は親切なエラーで
停止する）。Android と同じ **v0.86.5** に固定する:

```powershell
git -C D:\LINE_pt2\ios submodule add https://github.com/signalapp/libsignal crypto/third_party/libsignal
git -C D:\LINE_pt2\ios -C crypto/third_party/libsignal checkout v0.86.5
```

（2行目が通らない環境では: `cd D:\LINE_pt2\ios\crypto\third_party\libsignal; git checkout v0.86.5`）

## 2. git 初期化 & 初回コミット

```powershell
cd D:\LINE_pt2\ios
git init -b main
git add .
git commit -m "RichMan iOS: protocol core + libsignal crypto layer + CI"
```

## 3. GitHub リポジトリ作成 & push

`gh` は `Sexy-Frog` で認証済み。**公開／非公開はコストと秘匿性のトレードオフ**（下記）。

- 公開で作る（macOS 分が無料）:
  ```powershell
  gh repo create richman-ios --public --source=D:\LINE_pt2\ios --remote=origin --push
  ```
- 非公開で作る（macOS 分は課金／無料枠が少ない）:
  ```powershell
  gh repo create richman-ios --private --source=D:\LINE_pt2\ios --remote=origin --push
  ```

push 後、core ジョブは自動で回る。crypto（macOS）ジョブは **Actions タブ →
「iOS CI」→ Run workflow** で手動起動できる（または main への push で回る）。

## macOS ランナーのコスト（重要）

GitHub-hosted の **macOS ランナーは Linux の 10倍**課金される。

- **公開リポジトリ**: Actions は**無料**（パブリック向けの無料枠）。頻繁に回すなら実質これ一択。
  デメリットはコードが世界に見えること（ただし本アプリはプロトコル/暗号設計を公開しても
  問題ない設計＝Signal と同じ思想。サーバの鍵等は `ios/` に含まれていない）。
- **非公開リポジトリ**: Free プランの無料枠は 2,000 分/月だが macOS は 10倍換算なので
  **実質 ~200 macOS分/月**。crypto ジョブは Rust FFI のフルビルドで 1回あたり安く見ても
  15〜30分 → 課金換算 150〜300分。**無料枠で月1回程度**しか回せない。それ以上は従量課金。

> 「回す時だけ公開、終わったら非公開」は、公開中だけコードが露出するうえ切替が手動で
> 手間。頻繁に回すなら最初から公開、滅多に回さないなら非公開＋手動 dispatch が無難。

## FFI ビルドが落ちやすい点（初回に出たら対応）

- Rust ツールチェーン: libsignal の `rust-toolchain.toml` を rustup が自動取得する想定。
  macos-14 ランナーには rustup があるので通常は追加設定不要。
- `protoc` / `cmake`: 最近の libsignal は protobuf をソース同梱、cmake はランナーに在る。
  もし `protoc not found` 等が出たら crypto ジョブに `brew install protobuf` を足す。
- 初回は赤が出る前提で、ログを見て 1つずつ潰す（これが「一気にビルドしてバグ検査」の実体）。
