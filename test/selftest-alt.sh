#!/usr/bin/env bash
# ============================================================================
# selftest-alt.sh -- ALT-A / ALT-B (docs/alt-per-service-path.md) の検証
# ============================================================================
#   ALT-A: 全コンテナが /mnt/logs/front/logs/intra-web/tmp/... 1 ファイルを共有
#   ALT-B: ${APP_ROOT}/logs (既存 symlink) を踏み台にした 2 段解決で
#          サービス別・front/back 別の実体に自動で振り分けられること
# ============================================================================
set -euo pipefail
export MSYS=winsymlinks:nativestrict

HERE=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $*"; }
ng(){ FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
chk(){ if eval "$2"; then ok "$1"; else ng "$1"; fi; }
head1(){ echo; echo "=== $* ==========================================="; }

mkdir -p "$SB/shim"; printf '#!/bin/sh\nexit 0\n' > "$SB/shim/chown"; chmod +x "$SB/shim/chown"
export PATH="$SB/shim:$PATH"

mkdir -p "$SB/opt/app/shared-conf/bin"
cp "$HERE"/image/bin/*.sh "$SB/opt/app/shared-conf/bin/"
chmod +x "$SB"/opt/app/shared-conf/bin/*.sh

# サンドボックスの絶対パスに合わせて linkmap の /mnt/logs を書き換える
mk_linkmap() { sed "s|/mnt/logs|${SB}/mnt/logs|g" "$1" > "$2"; }

# 既存構成を再現: ${APP_ROOT}/logs -> ${SB}/mnt/logs/<role>/logs/<service>
setup() {   # $1=role $2=service $3=APP_ROOT
    local role="$1" svc="$2" root="$3"
    mkdir -p "$root/servlets/jp/co/sample/base"
    mkdir -p "$SB/mnt/logs/$role/logs/$svc"
    ln -sfn "$SB/mnt/logs/$role/logs/$svc" "$root/logs"
    printf 'date.format=yyyy/MM/dd\n' > "$root/servlets/jp/co/sample/base/date_config.properties"
}

build() {   # $1=tag $2=APP_ROOT $3=linkmap
    APP_ROOT="$2" DEFAULTS_DIR="$SB/defaults/$1" SHARED_CONF_LINKMAP="$3" \
        sh "$SB/opt/app/shared-conf/bin/build-shared-links.sh" >/dev/null
}
start() {   # $1=tag $2=APP_ROOT $3=linkmap $4=SHARED_CONF_DIR
    APP_ROOT="$2" DEFAULTS_DIR="$SB/defaults/$1" SHARED_CONF_LINKMAP="$3" \
        SHARED_CONF_DIR="$4" SHARED_CONF_MOUNT="$SB/mnt/logs" SHARED_CONF_WAIT=2 \
        sh "$SB/opt/app/shared-conf/bin/shared-conf-entrypoint.sh" true >/dev/null
}

# ---------------------------------------------------------------------------
head1 "ALT-A : 全コンテナが 1 ファイルを共有"
# ---------------------------------------------------------------------------
mk_linkmap "$HERE/image/linkmap.alt-a.conf.example" "$SB/alt-a.conf"
A_SHARED="$SB/mnt/logs/front/logs/intra-web/tmp"
declare -a A_LINKS=()
for svc in intra-api inter-api sf-api intra-web; do
    for role in front back; do
        [ "$role" = front ] && d=webapp9mf02 || d=webapp9mb02
        root="$SB/a/$svc/$role/webapp/$d"
        setup "$role" "$svc" "$root"
        build "a-$svc-$role" "$root" "$SB/alt-a.conf"
        start "a-$svc-$role" "$root" "$SB/alt-a.conf" "$A_SHARED"
        A_LINKS+=("$root/servlets/jp/co/sample/base/date_config.properties")
    done
done
chk "実体は intra-web 配下の 1 ファイルのみ" '[ "$(find "$A_SHARED" -type f | wc -l)" -eq 1 ]'
printf 'date.format=SHARED-EDIT\n' > "$A_SHARED/date_config.properties"
allsame=1
for l in "${A_LINKS[@]}"; do [ "$(cat "$l")" = "date.format=SHARED-EDIT" ] || allsame=0; done
chk "8 コンテナ全てに 1 回の編集が反映される" '[ "$allsame" -eq 1 ]'
chk "back コンテナも front ツリーを参照している (=A3 の指摘どおり)" \
    '[ "$(readlink "$SB/a/sf-api/back/webapp/webapp9mb02/servlets/jp/co/sample/base/date_config.properties")" = "$A_SHARED/date_config.properties" ]'

# ---------------------------------------------------------------------------
head1 "ALT-B : 既存 logs symlink 経由の 2 段解決でサービス別に振り分く"
# ---------------------------------------------------------------------------
mk_linkmap "$HERE/image/linkmap.alt-b.conf.example" "$SB/alt-b.conf"

# --- 先に 8 コンテナ分のツリーと EFS 側ディレクトリを用意する ---------------
# NOTE: Git Bash (MSYS) の `ln -s` は、リンク先が未作成のとき中間 symlink を
#       解決して保存してしまう (Linux は POSIX 準拠で常にリンク文字列をそのまま
#       保存するため、この前準備は Linux では不要)。
#       実運用でも EC2 側の init を先に流す手順なので、これが正しい順序でもある。
for svc in intra-api inter-api sf-api intra-web; do
    for role in front back; do
        [ "$role" = front ] && d=webapp9mf02 || d=webapp9mb02
        setup "$role" "$svc" "$SB/b/$svc/$role/webapp/$d"
    done
done
SKIP_MOUNT_CHECK=1 EFS_MNT="$SB/mnt/logs" \
    bash "$HERE/ec2/init-shared-conf-per-service.sh" init >/dev/null

declare -a B_LINKTARGETS=()
declare -a B_REALS=()
for svc in intra-api inter-api sf-api intra-web; do
    for role in front back; do
        [ "$role" = front ] && d=webapp9mf02 || d=webapp9mb02
        root="$SB/b/$svc/$role/webapp/$d"
        build "b-$svc-$role" "$root" "$SB/alt-b.conf"
        start "b-$svc-$role" "$root" "$SB/alt-b.conf" "$root/logs/tmp"
        link="$root/servlets/jp/co/sample/base/date_config.properties"
        # symlink -> ${APP_ROOT}/logs/tmp/... -> /mnt/logs/<role>/logs/<svc>/tmp/...
        B_LINKTARGETS+=("$(readlink "$link" | sed "s|$root|@APP_ROOT@|")")
        B_REALS+=("$(readlink -f "$link")")
    done
done
chk "linkmap の TARGET は 8 コンテナすべて同一 (=イメージ1種で済む)" \
    '[ "$(printf "%s\n" "${B_LINKTARGETS[@]}" | sort -u | wc -l)" -eq 1 ]'
chk "2 段解決の結果、実体は 8 個に振り分けられている" \
    '[ "$(printf "%s\n" "${B_REALS[@]}" | sort -u | wc -l)" -eq 8 ]'
chk "sf-api/back の実体が back ツリー配下になっている" \
    '[ "$(readlink -f "$SB/b/sf-api/back/webapp/webapp9mb02/servlets/jp/co/sample/base/date_config.properties")" = "$SB/mnt/logs/back/logs/sf-api/tmp/date_config.properties" ]'
printf 'date.format=SF-ONLY\n' > "$SB/mnt/logs/back/logs/sf-api/tmp/date_config.properties"
chk "サービス別に値を変えられる (sf-api/back のみ変化)" \
    '[ "$(cat "$SB/b/sf-api/back/webapp/webapp9mb02/servlets/jp/co/sample/base/date_config.properties")" = "date.format=SF-ONLY" ] && [ "$(cat "$SB/b/sf-api/front/webapp/webapp9mf02/servlets/jp/co/sample/base/date_config.properties")" = "date.format=yyyy/MM/dd" ]'

# ---------------------------------------------------------------------------
head1 "ALT-B : 8 箇所一括更新ツール"
# ---------------------------------------------------------------------------
printf 'date.format=yyyy-MM-dd\ndate.tz=Asia/Tokyo\n' > "$SB/seed.properties"
mv "$SB/seed.properties" "$SB/date_config.properties"
SKIP_MOUNT_CHECK=1 EFS_MNT="$SB/mnt/logs" \
    bash "$HERE/ec2/init-shared-conf-per-service.sh" sync "$SB/date_config.properties" >/dev/null
chk "sync 後、sf-api/back の差分が解消される" \
    '[ "$(sed -n 1p "$SB/b/sf-api/back/webapp/webapp9mb02/servlets/jp/co/sample/base/date_config.properties")" = "date.format=yyyy-MM-dd" ]'
chk "sync 後、8 箇所すべてが一致する" \
    'SKIP_MOUNT_CHECK=1 EFS_MNT="$SB/mnt/logs" bash "$HERE/ec2/init-shared-conf-per-service.sh" diff >/dev/null'

echo
echo "========================================================"
echo " PASS=$PASS  FAIL=$FAIL"
echo "========================================================"
[ "$FAIL" -eq 0 ]
