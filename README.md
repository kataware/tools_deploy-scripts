# deploy-scripts

複数プロジェクト（svn/git混在）のサーバ反映作業を共通化するデプロイスクリプト。
`deploy.sh` 本体はこのリポジトリで一元管理し、各プロジェクト側に置いた `.deploy` 設定ファイルでターゲットごとの接続先・処理内容を定義する。

## セットアップ

```bash
ln -s ~/tools/deploy-scripts/deploy.sh ~/bin/deploy
```

`~/bin` がPATHに通っていれば、どのディレクトリからでも `deploy` コマンドとして呼び出せる。

## 使い方

デプロイ対象プロジェクトのローカル作業ディレクトリ（＝`.deploy`があるディレクトリ）で実行する。

```bash
cd ~/path/to/your-project
deploy <target> [cnf]
```

- `target`: `.deploy` 内のセクション名（例: `45`, `prod`）
- `cnf`: 設定ファイルパス。省略時はカレントディレクトリの `./.deploy`

実行すると、対象サーバへ1回のssh接続内で以下を行う。

1. `path` 直下に `.git` があれば `git pull`、`.svn` があれば `svn up`
2. 成功後、`post_pull` があれば続けて実行

ローカルがgit管理下でupstream設定がある場合、未pushコミットがあれば警告して確認を求める（svnはpushの概念が無いため対象外）。

## `.deploy` の書式

ini形式。デプロイ対象プロジェクトのリポジトリ直下に置く（本リポジトリには含まれない）。

```ini
[45]
host=192.168.123.45
user=deploy-user
path=/var/www/vhosts/example.com
post_pull=php artisan config:clear && php artisan view:clear
password=xxxxxxxx
```

設定できるキーは以下の7つのみ。

| キー | 必須 | 説明 |
|---|---|---|
| `host` | ○ | 接続先ホスト名/IP。`~/.ssh/config`のHostエイリアス名でも可。`user@host`形式で直書きしても良い（後述） |
| `path` | ○ | 対象サーバ上のドキュメントルート（直下に`.git`または`.svn`がある想定） |
| `user` | - | 接続ユーザー名。指定すると`host`の前に付与して`ssh`に渡す |
| `identity_file` | - | 秘密鍵ファイル（pem等）のパス。指定すると`ssh -i`で渡す。`~`は展開される |
| `post_pull` | - | pull/up成功後にリモートで実行する任意コマンド |
| `password` | - | 鍵認証が無いホスト向け。sshパスワードを自動投入する（要`sshpass`） |
| `log` | - | デプロイログの出力先。省略/`false`で出力しない（既定）。`true`で`path`直下の`deploy.log`、パスを指定するとそこに追記（後述） |

サンプル: [.deploy.sample](.deploy.sample)

### 接続ユーザー・鍵ファイルの指定

`~/.ssh/config`を使わず`.deploy`だけで完結させたい場合は`user`・`identity_file`キーを使う。

```ini
[prod]
host=203.0.113.20
user=ec2-user
identity_file=~/.ssh/keys/example.pem
path=/var/www/vhosts/example.com
```

`~/.ssh/config`にHostエイリアスを作る方法も引き続き使える（ポートなど`user`/`identity_file`ではカバーしない項目をまとめたい場合はこちら）。

```
# ~/.ssh/config
Host example-prod
    HostName 203.0.113.20
    User deploy-user
    Port 22222
    IdentityFile ~/.ssh/id_ed25519_example
```

`host=user@192.168.123.45`のように`host`自体に`user@`を含める書き方も互換のため残っている。

### パスワード認証（`password`キー）

鍵認証が無いホスト向けに、`.deploy`に`password`を書いておくと`sshpass`経由で自動投入できる（`SSHPASS`環境変数経由。`sshpass -p`のようにコマンドライン引数には載せない）。

```bash
# sshpassのインストール（Debian/Ubuntu系）
sudo apt-get install sshpass
```

`password`未設定、または`sshpass`が無い環境では、従来通り`ssh -t`が対話式でパスワードを聞いてくるのでそのまま入力すればよい。

**`password`を書いた`.deploy`は必ずVCS管理から除外すること。** 除外しないと平文パスワードがリポジトリ履歴に残る。手順は [`.deploy`をVCS管理から除外する](#deployをvcs管理から除外する) を参照。

### デプロイログ（`log`キー）

`log`を設定すると、pull/post_pullの出力をターミナル表示はそのままに、リモート側のファイルにも追記する。

```ini
log=true              # path 直下の deploy.log に追記
log=./logs/deploy.log # path 基準の相対パスに追記（ディレクトリが無ければ自動作成）
log=/var/log/deploy/myproj.log # 絶対パスも可
```

未設定、または`log=false`の場合は従来通りログ出力なし。

- 各回の先頭に `===== YYYY-MM-DD HH:MM:SS [target] =====` の区切り行を書き込むので、複数回分の履歴が追記されていく
- `path`がgit/svnの作業コピーの場合、`deploy.log`はワークツリー内の未追跡ファイルとして見えるようになる。気になる場合はリモート側の`.gitignore`/`svn:ignore`に追加しておくとよい
- この機能は`exec > >(tee ...) 2>&1`というbash構文を使うため、**リモートのログインシェルがbashであること**が前提（一般的なLinuxサーバでは通常問題ない）

## `.deploy`をVCS管理から除外する

`password`を使う・使わないに関わらず、`.deploy`はプロジェクトごとの環境依存情報なのでリポジトリには含めない運用が望ましい。

### gitの場合

プロジェクトの`.gitignore`に追記する。

```
/.deploy
```

すでに`git add`済みでないか確認してから追記すること（`git ls-files | grep -x '.deploy'`で追跡済みか確認できる。追跡済みなら`git rm --cached .deploy`で外す）。

### svnの場合

作業コピーのルートで`svn:ignore`プロパティを設定する。

```bash
svn propset svn:ignore ".deploy" .
svn commit -m "add .deploy to svn:ignore" --depth=empty .
```

- `svn propset`はローカルの作業コピーに対する変更なので、他の開発者にも反映するには`svn commit`が必要
- 他に未コミットの変更が混在している場合は`--depth=empty`でプロパティ変更のみを対象にコミットできる（対象ファイルの変更は含まれない）
- コミット前に`svn status`でリポジトリと差分が無いか確認し、古い場合は先に`svn update`しておく（他の未コミット変更とコンフリクトしないか要確認）

## 鍵認証の構築

deploy.shが直接使うのは「ローカル→対象サーバ」の接続のみ。一方で、対象サーバ上で実行される`git pull`/`svn up`自体が「対象サーバ→gitリモート/svnリモート」への認証を別途必要とする。この2つは別レイヤーなので、それぞれ設定する。

### ローカル→対象サーバ

通常の鍵認証（`.deploy`の`identity_file`キーか`~/.ssh/config`の`IdentityFile`）か、鍵が無ければ前述の`password`キーで対応する。

### 対象サーバ→gitリモート（read-onlyデプロイキー）

対象サーバ上のgit pullが対話式でパスフレーズを聞いてくる場合、対象サーバの個人アカウントの鍵（`~/.ssh/id_rsa`等）を使い回しているのが原因であることが多い。pull専用・パスフレーズなし・可能ならread-only権限の鍵を分けて用意する。

1. 対象サーバ上で専用鍵を生成する（パスフレーズは空にする）

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/deploy_<project> -N "" -C "deploy-key for <project> (pull only)"
   ```

2. 公開鍵（`~/.ssh/deploy_<project>.pub`）をgitリモート側に登録する

   - **GitHub**: リポジトリの `Settings > Deploy keys > Add deploy key`。**「Allow write access」のチェックは外す**（read-onlyで登録できる）
   - **GitLab**: リポジトリの `Settings > Repository > Deploy keys`。ロールを read-only のまま登録
   - **自前gitサーバ（gitolite等）**: リポジトリ側の設定でread-onlyアクセスを持つユーザー/鍵として登録するか、`authorized_keys`に`command=`制限を付けて`git-upload-pack`のみ許可する

3. 対象サーバの`~/.ssh/config`でリモートのHostに対して鍵を指定する

   ```
   Host github.com
       IdentityFile ~/.ssh/deploy_<project>
       IdentitiesOnly yes
   ```

これで対象サーバ上の`git pull`が非対話・パスフレーズなしで完結する。

### 対象サーバ→svnリモート

svn+sshの場合も考え方は同じ（pull専用の鍵をサーバ側に分離する）。ただしsvnサーバ側の多くは「read-only」を鍵単位で細かく制御する仕組みを持たないため、以下のいずれかで対応する。

- svnサーバ側（`authorized_keys`）で`command=`によりsvnserveやsvn+sshの実行内容を制限する
- svnサーバに読み取り専用の別ユーザーを用意し、そのユーザーの鍵として登録する
- 上記が難しい場合は、パスフレーズなし鍵であること自体は許容し、鍵ファイルのパーミッション（`600`）・対象サーバへのアクセス制御で担保する

いずれの方法でも、**このデプロイ専用鍵と開発者個人の鍵は分離する**（漏洩時の被害範囲を「pullのみ」に限定するため）。

## 設計上の要点

- **VCS自動判定**: リモート側`path`直下に`.git`があれば`git pull`、`.svn`があれば`svn up`。判定・実行ともにリモートで行う（1回のssh接続内）
- **pull専任、pushは対象外**: リモートへのpull/upのみ。ローカルからリモートへのpushは持たない（手動運用のまま）
- **1接続にまとめる**: pullと`post_pull`は同一のssh呼び出し内で連続実行する（パスワード認証ホストで複数回入力させないため）
- **ログ出力は任意**: `log`キーを設定した場合のみリモート側で`tee`によりログファイルへ追記する（未設定時は従来通り出力なし）
- **pre/post-pushフックや`public/build`のrsync連携などは現状スコープ外**

より詳細な設計意図は [CLAUDE.md](CLAUDE.md) を参照。

## 開発

このリポジトリにビルド・テストの仕組みは無い（単一のbashスクリプト）。変更後は構文チェックのみ行う。

```bash
bash -n deploy.sh
```
