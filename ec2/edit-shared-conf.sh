#!/usr/bin/env bash
# ============================================================================
# edit-shared-conf.sh -- 【EC2 側】共有プロパティファイルの安全な編集ラッパ
# ============================================================================
# 素の vi / sed -i で編集すると次の事故が起きうる:
#   * root で保存 -> 所有者が root:root になり appuser(6301) が書けなくなる
#   * エディタの書き戻しで permission が 0600 等に変わりコンテナから読めなくなる
#   * 途中保存された壊れた properties をコンテナが読んでしまう
#
# このスクリプトは
#   1. 一時ファイルにコピーして編集させ
#   2. properties として最低限パースできるか検証し
#   3. バックアップを取ってから
#   4. 所有者/permission を維持したまま rename で置き換える (原子的)
# という手順を踏む。
#
# 実行例:
#   sudo ./edit-shared-conf.sh /mnt/logs/tmp/date_config.properties
#   sudo ./edit-shared-conf.sh --set date.format=yyyy-MM-dd /mnt/logs/tmp/date_config.properties
#   sudo ./edit-shared-conf.sh --show /mnt/logs/tmp/date_config.properties
# ============================================================================
set -euo pipefail

APP_UID=6301
APP_GID=6302
FILE_MODE=0664
BACKUP_KEEP=10
MODE=edit
SETS=()

usage() {
    cat <<'USAGE'
使い方: edit-shared-conf.sh [options] <properties-file>
  (無指定)          $EDITOR で編集
  --set k=v         キーを設定/更新 (複数指定可)。エディタを開かない
  --show            内容を表示するだけ
  --diff            直近バックアップとの差分を表示
  --uid <n>/--gid <n>   所有者 (既定 6301/6302)
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --set)  SETS+=("$2"); MODE=set; shift 2 ;;
        --show) MODE=show; shift ;;
        --diff) MODE=diff; shift ;;
        --uid)  APP_UID="$2"; shift 2 ;;
        --gid)  APP_GID="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "不明なオプション: $1" >&2; usage; exit 1 ;;
        *)  TARGET="$1"; shift ;;
    esac
done

: "${TARGET:?編集対象のファイルを指定してください}"

if [ ! -f "$TARGET" ]; then
    echo "ERROR: ファイルがありません: $TARGET" >&2
    echo "       先に ec2/init-shared-conf.sh を実行するか、ECS タスクを1度起動してください。" >&2
    exit 1
fi

DIR=$(dirname "$TARGET")
BASE=$(basename "$TARGET")
BAKDIR="${DIR}/.backup"

case "$MODE" in
show) cat "$TARGET"; exit 0 ;;
diff)
    last=$(ls -1t "${BAKDIR}/${BASE}."* 2>/dev/null | head -1 || true)
    if [ -z "$last" ]; then echo "バックアップがありません"; exit 0; fi
    diff -u --label "$last" --label "$TARGET" "$last" "$TARGET" || true
    exit 0
    ;;
esac

# ---- 1) 一時ファイルを作って編集 -------------------------------------------
TMP=$(mktemp "${DIR}/.edit.${BASE}.XXXXXX")
trap 'rm -f "$TMP"' EXIT
cp "$TARGET" "$TMP"

if [ "$MODE" = set ]; then
    for kv in "${SETS[@]}"; do
        key=${kv%%=*}
        val=${kv#*=}
        if [ "$key" = "$kv" ]; then
            echo "ERROR: --set は key=value 形式で指定してください: $kv" >&2
            exit 1
        fi
        # 既存キーがあれば置換、無ければ追記
        if grep -qE "^[[:space:]]*${key}[[:space:]]*[=:]" "$TMP"; then
            awk -v k="$key" -v v="$val" '
                $0 ~ "^[[:space:]]*"k"[[:space:]]*[=:]" { print k"="v; next }
                { print }
            ' "$TMP" > "${TMP}.new" && mv "${TMP}.new" "$TMP"
            echo "  更新: ${key}=${val}"
        else
            printf '%s=%s\n' "$key" "$val" >> "$TMP"
            echo "  追加: ${key}=${val}"
        fi
    done
else
    "${EDITOR:-vi}" "$TMP"
fi

# ---- 2) 変更がなければ終了 --------------------------------------------------
if cmp -s "$TARGET" "$TMP"; then
    echo "変更はありませんでした。"
    exit 0
fi

# ---- 3) properties としての最低限の検証 ------------------------------------
badline=$(grep -nvE '^[[:space:]]*($|[#!]|[^=:[:space:]][^=:]*[[:space:]]*[=:])' "$TMP" || true)
if [ -n "$badline" ]; then
    echo "ERROR: properties として解釈できない行があります:" >&2
    printf '%s\n' "$badline" | sed 's/^/       /' >&2
    echo "       中止しました (元ファイルは変更していません)。" >&2
    exit 1
fi
if [ ! -s "$TMP" ]; then
    echo "ERROR: 空ファイルになっています。中止しました。" >&2
    exit 1
fi

# ---- 4) バックアップ --------------------------------------------------------
mkdir -p "$BAKDIR"
chown "${APP_UID}:${APP_GID}" "$BAKDIR" 2>/dev/null || true
chmod 2775 "$BAKDIR" 2>/dev/null || true
bak="${BAKDIR}/${BASE}.$(date +%Y%m%d-%H%M%S)"
cp -p "$TARGET" "$bak"
echo "バックアップ: $bak"
# 古いバックアップを間引く
ls -1t "${BAKDIR}/${BASE}."* 2>/dev/null | tail -n "+$((BACKUP_KEEP + 1))" | xargs -r rm -f

# ---- 5) 所有者/権限を整えて原子的に置換 ------------------------------------
chown "${APP_UID}:${APP_GID}" "$TMP"
chmod "$FILE_MODE" "$TMP"
mv -f "$TMP" "$TARGET"     # 同一ディレクトリ内の rename = 原子的
trap - EXIT

echo "更新しました: $TARGET"
ls -lan "$TARGET" | sed 's/^/  /'
cat <<'NEXT'

注意: アプリが起動時に1回だけ Properties を load する実装の場合、
      この編集だけでは反映されません。ECS サービスの再デプロイが必要です。
        aws ecs update-service --cluster <cluster> --service <svc> --force-new-deployment

      SHARED_CONF_OVERLAY=on のイメージ (WAR への Deployment Overlay) を
      使っている場合は、サービス全体を再デプロイせずに
      コンテナ内で overlay を再適用するだけで反映できます。
        aws ecs execute-command --cluster <cluster> --task <task-id> --container front \
          --interactive --command "/opt/app/shared-conf/bin/deployment-overlay.sh apply"
      overlay は適用時点のコピーなので、編集しただけでは WAR 側に反映されません。
      詳細は docs/deployment-overlay.md §5.4。
NEXT
