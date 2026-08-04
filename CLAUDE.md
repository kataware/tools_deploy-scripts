# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

複数プロジェクト（svn/git混在）で個別にTeraTermマクロ等を組んでいたサーバ反映作業を置き換える、共通デプロイスクリプト。
`deploy.sh` 本体は複数案件で使い回し、各プロジェクト側（このリポジトリの外）に置いた `.deploy` 設定ファイルでターゲットごとの接続先・処理内容を定義する。

- 本体はこのリポジトリ（`~/tools/deploy-scripts`）で管理し、`~/bin/deploy` にシンボリックリンクしてPATH経由で呼び出す運用。
- 設定ファイル（`.deploy`）は各プロジェクトのリポジトリ側に置く（本リポジトリには含まれない）。

## 使い方

```bash
deploy.sh <target> [cnf]
```

- `target`: `.deploy` 内のセクション名（例: `45`, `prod`）
- `cnf`: 設定ファイルパス。省略時はカレントディレクトリの `./.deploy`
- 呼び出し元のカレントディレクトリ＝デプロイ対象プロジェクトのローカル作業ディレクトリを想定（未pushコミットのチェックに使う）

### 構文チェック（テストに相当するもの）

このリポジトリにはビルド・テストの仕組みはない（単一のbashスクリプト）。変更後は構文チェックのみ行う。

```bash
bash -n deploy.sh
```

## 設定ファイル（`.deploy`）の書式

ini形式。プロジェクト側のリポジトリ直下に置く想定。

```ini
[45]
host=192.168.123.45
user=deploy-user
identity_file=~/.ssh/keys/example.pem
path=/var/www/vhosts/example.com
post_pull=php artisan config:clear && php artisan view:clear
password=xxxxxxxx
```

- `host`: 接続先ホスト名/IP。`~/.ssh/config` のHostエイリアス名でも可。`host=user@192.168.123.45` のように user@ を直書きする互換記法も残っている
- `user`: 省略可。接続ユーザー名。指定すると `host` の前に付与して `user@host` として `ssh` に渡す（`host` に user@ を直書きする代替）
- `identity_file`: 省略可。秘密鍵ファイル（pem等）のパス。指定すると `ssh -i` で渡す（`~` は `$HOME` に展開してから渡す。ssh自体はvar経由の `~` を展開しないため）。`~/.ssh/config` の `IdentityFile` を使わずに `.deploy` だけで完結させたい場合用
- `path`: 対象サーバ上のドキュメントルート
- `post_pull`: pull/up成功後にリモートで実行する任意コマンド（キャッシュクリア、chmod/chown等）。プロジェクトごとに自由記述。スクリプト側で特別扱いしているコマンドはない
- `password`: 省略可。鍵認証が無いホスト向けにsshパスワードを自動投入する（`sshpass`が必要。無ければ従来通り対話プロンプトにフォールバック）。**このキーを使う `.deploy` は必ずgitignore/svn:ignoreでVCS管理から除外すること**

## 設計上の要点

- **VCS自動判定**: リモート側 `path` 直下に `.git` があれば `git pull`、`.svn` があれば `svn up`。判定・実行ともにリモートで行う（1回のssh接続内）。
- **pull専任、pushは対象外**: このスクリプトはリモートへのpull/upのみを行う。ローカルからリモートへのpush操作は持たない（今まで通り手動）。
- **未push警告**: ローカルが git 管理下かつ upstream が設定されている場合、`git log @{u}..HEAD` で未pushコミットの有無を確認し、あれば警告して確認プロンプトを出す（svnはpushの概念が無いため対象外）。
- **パスワードは任意でsshpass経由**: `password` キーを設定すると `SSHPASS`環境変数経由で`sshpass -e`にパスワードを渡し、`ssh -t`を非対話で通す（argvに直接載せる`sshpass -p`は使わない）。`password`未設定、または`sshpass`が無い環境では従来通り`ssh -t`の対話プロンプトにフォールバックする。`password`を書いた`.deploy`は各プロジェクト側で必ずVCS管理から除外する（git: `.gitignore`、svn: `svn:ignore`プロパティ）。スクリプト本体にはパスワードを持たせない。
- **1接続にまとめる**: pullと`post_pull`は同一の `ssh` 呼び出し内で連続実行する（`&&` 連結）。接続を分けるとパスワード認証ホストで複数回パスワード入力が必要になるため。
- **ホスト鍵の初回自動登録**: `ssh`/`sshpass` 呼び出しに `-o StrictHostKeyChecking=accept-new` を付与。未登録ホストの鍵は自動登録するが、登録済みの鍵と相違があった場合は従来通り拒否される（MITM対策は維持）。特に`password`（sshpass経由）使用時、sshpassはfingerprint確認プロンプトに応答できず無言で失敗する（sshpass exit 6）ため、これが無いと初回接続が原因不明のまま失敗する。
- **失敗時の診断メッセージ**: ssh/sshpassの終了コード（5=sshpass認証失敗、6=sshpassホスト鍵未確認、255=ssh接続エラー等）に応じて原因のヒントをstderrに出す。`set -e`だけに任せると無言で終了するため。
- **pre/post-pushフックや `public/build` のrsync連携などは現状スコープ外**（意図的に持たせていない）。
