#!/usr/bin/env bash
# 複数プロジェクト共通デプロイスクリプト（svn/git両対応）
#
# Usage: deploy.sh <target> [cnf]
#   target : cnfファイル内のセクション名（例: 45, prod）
#   cnf    : 設定ファイルのパス（省略時は ./.deploy）
#
# cnfファイル書式（ini形式）:
#   [45]
#   host=192.168.123.45                    # ~/.ssh/config のHostエイリアスでも生ホスト名/IPでも可（user@host形式も可）
#   user=deploy-user                       # 省略可。指定すると host の前に付与してsshに渡す（host側にuser@を書く代替）
#   identity_file=~/.ssh/keys/example.pem  # 省略可。秘密鍵ファイル（pem等）を指定してssh -iで渡す
#   path=/var/www/vhosts/example.com
#   post_pull=php artisan config:clear && php artisan view:clear
#   password=xxxxx                # 省略可。鍵認証が無いホスト向け（sshpass必須。.deployは各プロジェクト側でVCS管理から除外すること）
#   log=true                      # 省略可(既定false=出力しない)。trueで path 直下の deploy.log に追記、パスを指定するとそこに追記する（相対パスは path 基準）
#
# passwordが未設定、またはsshpassが無い場合は ssh が対話式でパスワードを聞いてくるのでそのまま入力すればよい。
# logはリモートのログインシェルがbashであることが前提（exec > >(tee ...) を使用するため）。

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <target> [cnf]" >&2
    exit 1
}

target="${1:-}"
cnf="${2:-./.deploy}"

[ -n "$target" ] || usage

if [ ! -f "$cnf" ]; then
    echo "設定ファイルが見つかりません: $cnf" >&2
    exit 1
fi

get_ini_value() {
    local key="$1"
    awk -F'=' -v section="[$target]" -v key="$key" '
        $0 == section { in_section=1; next }
        /^\[/          { in_section=0 }
        in_section && $1 ~ "^[ \t]*" key "[ \t]*$" {
            sub(/^[^=]*=/, "")
            sub(/^[ \t]+/, "")
            sub(/[ \t]+$/, "")
            print
            exit
        }
    ' "$cnf"
}

host=$(get_ini_value "host")
path=$(get_ini_value "path")
post_pull=$(get_ini_value "post_pull")
password=$(get_ini_value "password")
user=$(get_ini_value "user")
identity_file=$(get_ini_value "identity_file")
log=$(get_ini_value "log")

if [ -z "$host" ] || [ -z "$path" ]; then
    echo "対象 [$target] が見つからないか host/path が未設定です（$cnf）" >&2
    exit 1
fi

log_target=""
if [ -n "$log" ] && [ "$log" != "false" ]; then
    if [ "$log" = "true" ]; then
        log_target="deploy.log"
    else
        log_target="$log"
    fi
fi

if [ -n "$user" ]; then
    ssh_target="$user@$host"
else
    ssh_target="$host"
fi

ssh_opts=(-o StrictHostKeyChecking=accept-new)
if [ -n "$identity_file" ]; then
    identity_file="${identity_file/#\~/$HOME}"
    ssh_opts+=(-i "$identity_file")
fi

# ローカルに未pushのコミットがないか警告（gitのみ。svnはpush概念が無いため対象外）
if [ -d .git ]; then
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [ -n "$upstream" ]; then
        unpushed=$(git log "$upstream"..HEAD --oneline 2>/dev/null || true)
        if [ -n "$unpushed" ]; then
            echo "警告: ローカルに未pushのコミットがあります（$upstream との差分）:" >&2
            echo "$unpushed" >&2
            read -r -p "このままデプロイを続けますか？ [y/N] " ans
            case "$ans" in
                [yY]*) ;;
                *) echo "中断しました。" >&2; exit 1 ;;
            esac
        fi
    fi
fi

remote_cmd=$(cat <<EOS
set -e
cd "$path"
EOS
)

if [ -n "$log_target" ]; then
    remote_cmd="$remote_cmd
$(cat <<EOS
mkdir -p "\$(dirname "$log_target")"
exec > >(tee -a "$log_target") 2>&1
echo "===== \$(date '+%Y-%m-%d %H:%M:%S') [$target] ====="
EOS
)"
fi

remote_cmd="$remote_cmd
$(cat <<EOS
if [ -d .git ]; then
    git pull
elif [ -d .svn ]; then
    svn up
else
    echo "エラー: $path に .git も .svn も見つかりません" >&2
    exit 1
fi
EOS
)"

if [ -n "$post_pull" ]; then
    remote_cmd="$remote_cmd
$post_pull"
fi

echo "==> [$target] $ssh_target:$path へデプロイします"

use_sshpass=0
if [ -n "$password" ]; then
    if command -v sshpass >/dev/null 2>&1; then
        use_sshpass=1
    else
        echo "警告: passwordが設定されていますがsshpassが見つかりません。対話プロンプトにフォールバックします" >&2
    fi
fi

# StrictHostKeyChecking=accept-new: 未登録ホストの鍵は自動登録するが、
# 登録済みの鍵と相違があった場合は従来通り拒否される（MITM対策は維持）
set +e
if [ "$use_sshpass" -eq 1 ]; then
    SSHPASS="$password" sshpass -e ssh "${ssh_opts[@]}" -t "$ssh_target" "$remote_cmd"
else
    ssh "${ssh_opts[@]}" -t "$ssh_target" "$remote_cmd"
fi
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
    if [ "$use_sshpass" -eq 1 ] && [ "$rc" -eq 6 ]; then
        echo "エラー: ホスト鍵が未確認のためsshpassが接続を中断しました（sshpass exit 6）。一度 'ssh ${ssh_opts[*]} $ssh_target' を手動実行してホスト鍵を確認・登録してから再実行してください。" >&2
    elif [ "$use_sshpass" -eq 1 ] && [ "$rc" -eq 5 ]; then
        echo "エラー: sshpassでの認証に失敗しました。.deploy の password を確認してください（sshpass exit 5）。" >&2
    elif [ "$rc" -eq 255 ]; then
        echo "エラー: ssh接続に失敗しました。host設定やネットワーク、ホスト鍵の変更（上記のssh出力）を確認してください。" >&2
    else
        echo "エラー: デプロイに失敗しました (exit code: $rc)。リモートコマンド（pull/post_pull）の出力を確認してください。" >&2
    fi
    exit "$rc"
fi
