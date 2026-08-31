#!/usr/bin/env bash
# ============================================================================
# init-shared-conf-per-service.sh -- 【ALT-B 用 / EC2 側】
#   サービス別・front/back 別に散らばる実体 (4 x 2 = 8 個) をまとめて操作する
# ============================================================================
# ALT-B では実体が
#     /mnt/logs/front/logs/<service>/tmp/<file>
#     /mnt/logs/back/logs/<service>/tmp/<file>
# の 8 箇所に分かれるため、「1 箇所直せば全部反映」ができない。
# その弱点 (docs/alt-per-service-path.md の B1/B2) を埋めるためのツール。
#
#   init            8 ディレクトリを 6301:6302 / 2775 で作成
#   sync <src>      <src> の内容を 8 ファイルすべてへ一括反映 (バックアップあり)
#   diff            8 ファイルの内容が揃っているか確認
#   list            8 ファイルの状態を一覧表示
#
# 実行例:
#   sudo ./init-shared-conf-per-service.sh init
#   sudo ./init-shared-conf-per-service.sh sync ./seed/date_config.properties
#   sudo ./init-shared-conf-per-service.sh diff
# ============================================================================
set -euo pipefail

APP_UID=6301
APP_GID=6302
DIR_MODE=2775
FILE_MODE=0664

EFS_MNT=${EFS_MNT:-/mnt/logs}
CONF_SUBDIR=${CONF_SUBDIR:-tmp}
SERVICES=(${SERVICES:-intra-api inter-api sf-api intra-web})
ROLES=(${ROLES:-front back})
FILES=(${FILES:-date_config.properties})

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# 対象ディレクトリを列挙
each_dir() {
    local role svc
    for role in "${ROLES[@]}"; do
        for svc in "${SERVICES[@]}"; do
            echo "${EFS_MNT}/${role}/logs/${svc}/${CONF_SUBDIR}"
        done
    done
}

# 対象ファイルを列挙
each_file() {
    local d f
    while read -r d; do
        for f in "${FILES[@]}"; do
            echo "${d}/${f}"
        done
    done < <(each_dir)
}

require_mount() {
    # EFS が /mnt 等に階層マウントされていて ${EFS_MNT} 自体は mountpoint でない
    # 構成や、検証時のサンドボックスでは SKIP_MOUNT_CHECK=1 で回避できる。
    [ "${SKIP_MOUNT_CHECK:-0}" = "1" ] && return 0
    if ! mountpoint -q "$EFS_MNT"; then
        echo "ERROR: ${EFS_MNT} がマウントされていません。" >&2
        echo "       階層マウント構成なら SKIP_MOUNT_CHECK=1 を付けて実行してください。" >&2
        exit 1
    fi
}

cmd_init() {
    require_mount
    local d
    while read -r d; do
        mkdir -p "$d"
        chown "${APP_UID}:${APP_GID}" "$d"
        chmod "$DIR_MODE" "$d"
        echo "  作成/確認: $d"
    done < <(each_dir)
    echo "init 完了 ($(each_dir | wc -l) ディレクトリ)"
}

cmd_sync() {
    local src="${1:-}"
    [ -f "$src" ] || { echo "ERROR: シードファイルを指定してください" >&2; exit 1; }
    require_mount

    # properties としての最低限の検証 (壊れた内容を 8 箇所へ配る事故を防ぐ)
    local badline
    badline=$(grep -nvE '^[[:space:]]*($|[#!]|[^=:[:space:]][^=:]*[[:space:]]*[=:])' "$src" || true)
    if [ -n "$badline" ]; then
        echo "ERROR: properties として解釈できない行があります:" >&2
        printf '%s\n' "$badline" | sed 's/^/       /' >&2
        exit 1
    fi

    local base ts f n=0
    base=$(basename "$src")
    ts=$(date +%Y%m%d-%H%M%S)

    while read -r f; do
        [ "$(basename "$f")" = "$base" ] || continue
        mkdir -p "$(dirname "$f")"
        if [ -f "$f" ]; then
            if cmp -s "$src" "$f"; then
                echo "  変更なし: $f"
                continue
            fi
            local bakdir="$(dirname "$f")/.backup"
            mkdir -p "$bakdir"
            chown "${APP_UID}:${APP_GID}" "$bakdir" 2>/dev/null || true
            cp -p "$f" "${bakdir}/${base}.${ts}"
        fi
        # 同一ディレクトリ内に作ってから rename = 原子的に置換
        local tmp
        tmp=$(mktemp "$(dirname "$f")/.sync.${base}.XXXXXX")
        cp "$src" "$tmp"
        chown "${APP_UID}:${APP_GID}" "$tmp"
        chmod "$FILE_MODE" "$tmp"
        mv -f "$tmp" "$f"
        echo "  更新: $f"
        n=$((n+1))
    done < <(each_file)

    echo "sync 完了 (${n} ファイル更新)"
    echo
    echo "注意: アプリが起動時に1回だけ読む実装なら、全 4 サービスの再デプロイが必要です。"
}

cmd_diff() {
    local f first="" rc=0
    for target in "${FILES[@]}"; do
        echo "=== ${target} ==="
        first=""
        while read -r f; do
            [ "$(basename "$f")" = "$target" ] || continue
            if [ ! -f "$f" ]; then
                echo "  [欠落] $f"; rc=1; continue
            fi
            if [ -z "$first" ]; then
                first="$f"
                echo "  [基準] $f"
                continue
            fi
            if cmp -s "$first" "$f"; then
                echo "  [一致] $f"
            else
                echo "  [差分] $f"
                diff -u --label "$first" --label "$f" "$first" "$f" | sed 's/^/        /' || true
                rc=1
            fi
        done < <(each_file)
        echo
    done
    [ "$rc" -eq 0 ] && echo "すべて一致しています。" || echo "不整合があります。sync で揃えてください。"
    return "$rc"
}

cmd_list() {
    local f
    while read -r f; do
        if [ -f "$f" ]; then
            printf '  %s  %s\n' "$(stat -c '%U:%G %a %y' "$f" 2>/dev/null | cut -c1-30)" "$f"
        else
            printf '  %-30s %s\n' "(なし)" "$f"
        fi
    done < <(each_file)
}

case "${1:-}" in
    init) shift; cmd_init "$@" ;;
    sync) shift; cmd_sync "$@" ;;
    diff) shift; cmd_diff "$@" ;;
    list) shift; cmd_list "$@" ;;
    -h|--help|"") usage 0 ;;
    *) echo "不明なサブコマンド: $1" >&2; usage 1 ;;
esac
