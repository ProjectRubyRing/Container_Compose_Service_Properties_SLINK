#!/usr/bin/env bash
# ============================================================================
# init-shared-conf.sh -- 【EC2 (RHEL 9.8) 側】共有設定ディレクトリの初期構築
# ============================================================================
# EFS (/mnt/logs) をマウントした EC2 上で1回だけ実行する。
# ECS タスクの entrypoint にもシード機能はあるが、
#   * 内容を確定させたい (front/back のどちらが先に起動しても同じ内容にする)
#   * /mnt/logs 直下に mkdir する権限がタスク側に無いケースがある
# ため、こちらを「正」として先に流しておくことを推奨する。
#
# 実行例:
#   sudo ./init-shared-conf.sh
#   sudo ./init-shared-conf.sh --dir /mnt/logs/tmp --seed ./seed/date_config.properties
# ============================================================================
set -euo pipefail

APP_UID=6301
APP_GID=6302
SHARED_CONF_DIR=/mnt/logs/tmp
DIR_MODE=2775          # setgid: 中で作られたファイルの group が appgroup になる
FILE_MODE=0664
SEED_FILES=()
DRY_RUN=0

usage() {
    cat <<'USAGE'
使い方: init-shared-conf.sh [options]
  --dir  <path>    共有設定ディレクトリ (既定: /mnt/logs/tmp)
  --seed <file>    初期配置するファイル (複数指定可 / basename で配置される)
  --uid  <n>       所有ユーザ  (既定: 6301)
  --gid  <n>       所有グループ (既定: 6302)
  --dry-run        実行内容の表示のみ
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)     SHARED_CONF_DIR="$2"; shift 2 ;;
        --seed)    SEED_FILES+=("$2");   shift 2 ;;
        --uid)     APP_UID="$2";         shift 2 ;;
        --gid)     APP_GID="$2";         shift 2 ;;
        --dry-run) DRY_RUN=1;            shift   ;;
        -h|--help) usage; exit 0 ;;
        *) echo "不明なオプション: $1" >&2; usage; exit 1 ;;
    esac
done

run() {
    if [ "$DRY_RUN" -eq 1 ]; then echo "  (dry-run) $*"; else "$@"; fi
}

# EFS マウントポイントは SHARED_CONF_DIR の先頭2階層 (/mnt/logs)
EFS_MNT=$(printf '%s' "$SHARED_CONF_DIR" | sed -e 's|^\(/[^/]*/[^/]*\).*|\1|')

echo "=== 共有設定ディレクトリ初期化 ==="
echo "  EFS マウント : ${EFS_MNT}"
echo "  対象ディレクトリ: ${SHARED_CONF_DIR}"
echo "  所有者        : ${APP_UID}:${APP_GID}"
echo

# ---- 1) EFS がマウントされているか -----------------------------------------
if [ "${SKIP_MOUNT_CHECK:-0}" = "1" ]; then
    echo "[1/4] SKIP_MOUNT_CHECK=1 のためマウント確認をスキップしました"
elif ! mountpoint -q "$EFS_MNT"; then
    echo "ERROR: ${EFS_MNT} がマウントされていません。" >&2
    echo "       /etc/fstab または mount コマンドを確認してください。" >&2
    echo "       階層マウント構成なら SKIP_MOUNT_CHECK=1 を付けて実行してください。" >&2
    exit 1
else
    echo "[1/4] ${EFS_MNT} のマウントを確認しました"
fi

# ---- 2) ディレクトリ作成 ----------------------------------------------------
run mkdir -p "$SHARED_CONF_DIR"
run chown "${APP_UID}:${APP_GID}" "$SHARED_CONF_DIR"
run chmod "$DIR_MODE" "$SHARED_CONF_DIR"
echo "[2/4] ${SHARED_CONF_DIR} を作成しました (mode=${DIR_MODE})"

# ---- 3) 初期ファイルの配置 (既存は絶対に上書きしない) ----------------------
if [ "${#SEED_FILES[@]}" -eq 0 ]; then
    echo "[3/4] --seed 指定なし。実体ファイルは ECS タスク起動時に"
    echo "      イメージ同梱の初期値から自動生成されます。"
else
    for src in "${SEED_FILES[@]}"; do
        if [ ! -f "$src" ]; then
            echo "ERROR: シードファイルが見つかりません: $src" >&2
            exit 1
        fi
        dst="${SHARED_CONF_DIR}/$(basename "$src")"
        if [ -e "$dst" ]; then
            echo "      既存のためスキップ (内容維持): $dst"
            continue
        fi
        run install -o "$APP_UID" -g "$APP_GID" -m "$FILE_MODE" "$src" "$dst"
        echo "      配置しました: $dst"
    done
    echo "[3/4] 初期ファイルの配置が完了しました"
fi

# ---- 4) 結果確認 ------------------------------------------------------------
echo "[4/4] 現在の状態:"
if [ "$DRY_RUN" -eq 0 ]; then
    ls -lan "$SHARED_CONF_DIR" | sed 's/^/      /'
fi

cat <<NEXT

--- 次にやること ---------------------------------------------------
 1. ファイルを編集する場合は必ず ec2/edit-shared-conf.sh を使うこと。
    (所有者 ${APP_UID}:${APP_GID} と permission ${FILE_MODE} を維持するため)

      sudo ./ec2/edit-shared-conf.sh ${SHARED_CONF_DIR}/date_config.properties

 2. アプリが起動時に1回だけ読む実装であれば、編集後に
    ECS サービスを再デプロイして反映させること。

      aws ecs update-service --cluster <cluster> --service intra-api  --force-new-deployment
      aws ecs update-service --cluster <cluster> --service inter-api  --force-new-deployment
      aws ecs update-service --cluster <cluster> --service sf-api     --force-new-deployment
      aws ecs update-service --cluster <cluster> --service intra-web  --force-new-deployment
--------------------------------------------------------------------
NEXT
