#!/usr/bin/env bash
# 複数プロジェクト共通デプロイスクリプト（svn/git両対応）
#
# Usage: deploy.sh <target> [cnf]
#   target : cnfファイル内のセクション名（例: 45, prod）
#   cnf    : 設定ファイルのパス（省略時は ./.deploy）
#
# cnfファイル書式（ini形式）:
#   [45]
#   host=192.168.123.45          # ~/.ssh/config のHostエイリアスでも生ホスト名/IPでも可
#   path=/var/www/vhosts/example.com
#   post_pull=php artisan config:clear && php artisan view:clear
#   password=xxxxx                # 省略可。鍵認証が無いホスト向け（sshpass必須。.deployは各プロジェクト側でVCS管理から除外すること）
#
# passwordが未設定、またはsshpassが無い場合は ssh が対話式でパスワードを聞いてくるのでそのまま入力すればよい。

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

if [ -z "$host" ] || [ -z "$path" ]; then
    echo "対象 [$target] が見つからないか host/path が未設定です（$cnf）" >&2
    exit 1
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
if [ -d .git ]; then
    git pull
elif [ -d .svn ]; then
    svn up
else
    echo "エラー: $path に .git も .svn も見つかりません" >&2
    exit 1
fi
EOS
)

if [ -n "$post_pull" ]; then
    remote_cmd="$remote_cmd
$post_pull"
fi

echo "==> [$target] $host:$path へデプロイします"

if [ -n "$password" ]; then
    if command -v sshpass >/dev/null 2>&1; then
        SSHPASS="$password" sshpass -e ssh -t "$host" "$remote_cmd"
    else
        echo "警告: passwordが設定されていますがsshpassが見つかりません。対話プロンプトにフォールバックします" >&2
        ssh -t "$host" "$remote_cmd"
    fi
else
    ssh -t "$host" "$remote_cmd"
fi
