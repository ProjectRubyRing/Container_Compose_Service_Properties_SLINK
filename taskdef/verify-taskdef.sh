#!/usr/bin/env bash
# ============================================================================
# verify-taskdef.sh -- 既存タスク定義が「共有できる状態」かを事前チェックする
# ============================================================================
# 最大の落とし穴は、front と back で efsVolumeConfiguration.rootDirectory が
# 違っていること。例えば back が rootDirectory="/back" になっていると、
# back コンテナの /mnt/logs/tmp は EFS 上の /back/tmp を指すため、
# front と同じファイルを共有できない。
#
# 実行例:
#   ./verify-taskdef.sh intra-api inter-api sf-api intra-web
#   ./verify-taskdef.sh --file taskdef/taskdef-intra-web.example.json
# ============================================================================
set -uo pipefail

MOUNT_PATH=${MOUNT_PATH:-/mnt/logs}
FILES=()
FAMILIES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --file)  FILES+=("$2"); shift 2 ;;
        --mount) MOUNT_PATH="$2"; shift 2 ;;
        *)       FAMILIES+=("$1"); shift ;;
    esac
done

command -v jq >/dev/null || { echo "jq が必要です (dnf install -y jq)" >&2; exit 1; }

RC=0

check_json() {
    local label="$1" json="$2"

    echo "=== ${label} ==============================================="

    # containerPath=/mnt/logs のマウントを持つコンテナごとに
    #   コンテナ名 / sourceVolume / readOnly / user / readonlyRootFilesystem
    # を取り出す
    local rows
    rows=$(jq -r --arg mp "$MOUNT_PATH" '
        .containerDefinitions[]
        | . as $c
        | ($c.mountPoints // [])[]
        | select(.containerPath == $mp)
        | [ $c.name,
            .sourceVolume,
            (.readOnly // false | tostring),
            ($c.user // "(未設定=root)"),
            ($c.readonlyRootFilesystem // false | tostring)
          ] | @tsv
    ' <<<"$json")

    if [ -z "$rows" ]; then
        echo "  [NG] ${MOUNT_PATH} をマウントしているコンテナがありません"
        RC=1
        echo
        return
    fi

    local n=0
    while IFS=$'\t' read -r cname svol ro user rorfs; do
        n=$((n+1))
        # そのボリュームの EFS 設定
        local fsid rootdir
        fsid=$(jq -r --arg v "$svol"    '.volumes[] | select(.name==$v) | .efsVolumeConfiguration.fileSystemId // "N/A"'    <<<"$json")
        rootdir=$(jq -r --arg v "$svol" '.volumes[] | select(.name==$v) | .efsVolumeConfiguration.rootDirectory // "/"'     <<<"$json")

        printf '  %-8s volume=%-10s fs=%-22s rootDir=%-8s readOnly=%-5s user=%-12s roRootFS=%s\n' \
               "$cname" "$svol" "$fsid" "$rootdir" "$ro" "$user" "$rorfs"

        [ "$ro" = "true" ] && { echo "    [NG] ${MOUNT_PATH} が readOnly=true です。実体の初回生成ができません"; RC=1; }
        [ "$user" = "(未設定=root)" ] && { echo "    [WARN] user が未設定です。6301:6302 を明示してください"; }
        [ "$fsid" = "N/A" ] && { echo "    [NG] EFS ボリュームではありません"; RC=1; }

        echo "${fsid}|${rootdir}"  >> "$TMPKEY"
    done <<<"$rows"

    # front / back で fsid + rootDirectory が一致しているか
    local uniq
    uniq=$(sort -u "$TMPKEY" | wc -l)
    if [ "$uniq" -gt 1 ]; then
        echo "  [NG] コンテナ間で fileSystemId / rootDirectory が一致していません:"
        sort -u "$TMPKEY" | sed 's/^/       /'
        echo "       -> ${MOUNT_PATH}/tmp が front/back で別ファイルになります"
        RC=1
    else
        echo "  [OK] 全コンテナが同一 EFS / 同一 rootDirectory を参照しています ($(cat "$TMPKEY" | head -1))"
        echo "       -> ${MOUNT_PATH}/tmp/date_config.properties は共有されます"
    fi
    : > "$TMPKEY"
    echo
}

TMPKEY=$(mktemp); trap 'rm -f "$TMPKEY"' EXIT

for f in "${FILES[@]:-}"; do
    [ -z "$f" ] && continue
    check_json "$f" "$(cat "$f")"
done

for fam in "${FAMILIES[@]:-}"; do
    [ -z "$fam" ] && continue
    json=$(aws ecs describe-task-definition --task-definition "$fam" --query taskDefinition --output json 2>/dev/null)
    if [ -z "$json" ]; then
        echo "=== ${fam} ==="; echo "  [NG] タスク定義を取得できませんでした"; echo; RC=1; continue
    fi
    check_json "$fam" "$json"
done

if [ "$RC" -eq 0 ]; then
    echo "すべて OK: タスク定義の変更なしで今回の対応を適用できます。"
else
    echo "NG があります。上記を解消してから適用してください。"
fi
exit "$RC"
