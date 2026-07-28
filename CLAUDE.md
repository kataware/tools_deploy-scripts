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
path=/var/www/vhosts/example.com
post_pull=php artisan config:clear && php artisan view:clear
```

- `host`: 接続先。`~/.ssh/config` のHostエイリアス名でも、生ホスト名/IPでも可（`ssh $host` にそのまま渡すため、鍵の有無やポート等の接続詳細はssh側の設定に委ねる）
- `path`: 対象サーバ上のドキュメントルート
- `post_pull`: pull/up成功後にリモートで実行する任意コマンド（キャッシュクリア、chmod/chown等）。プロジェクトごとに自由記述。スクリプト側で特別扱いしているコマンドはない

## 設計上の要点

- **VCS自動判定**: リモート側 `path` 直下に `.git` があれば `git pull`、`.svn` があれば `svn up`。判定・実行ともにリモートで行う（1回のssh接続内）。
- **pull専任、pushは対象外**: このスクリプトはリモートへのpull/upのみを行う。ローカルからリモートへのpush操作は持たない（今まで通り手動）。
- **未push警告**: ローカルが git 管理下かつ upstream が設定されている場合、`git log @{u}..HEAD` で未pushコミットの有無を確認し、あれば警告して確認プロンプトを出す（svnはpushの概念が無いため対象外）。
- **パスワードは埋め込まない**: `.deploy` にもスクリプト本体にも認証情報は持たせない。鍵認証のないホストは `ssh -t` の対話プロンプトでそのままパスワードを入力する運用（旧TeraTermマクロのような平文埋め込みは踏襲しない）。
- **1接続にまとめる**: pullと`post_pull`は同一の `ssh` 呼び出し内で連続実行する（`&&` 連結）。接続を分けるとパスワード認証ホストで複数回パスワード入力が必要になるため。
- **pre/post-pushフックや `public/build` のrsync連携などは現状スコープ外**（意図的に持たせていない）。
