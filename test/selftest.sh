#!/usr/bin/env bash
# ============================================================================
# selftest.sh -- 実装のエンドツーエンド検証 (実 EFS 不要 / サンドボックスで再現)
# ============================================================================
# 検証内容:
#   1. ビルド時: /webapp 配下の実ファイルが symlink に置換され、初期値が退避される
#   2. 実行時 : 実体が無ければ初期値から生成される (front が先)
#   3. 共有   : back コンテナは front が作った同一実体を参照する
#   4. 再起動 : 既存の実体は上書きされない (編集内容が維持される)
#   5. 反映   : EC2 側 (= サンドボックス側) の編集が全コンテナから見える
#   6. 並行   : 同時起動しても実体は1つ / 壊れない
#
# 使い方:  bash test/selftest.sh
# ============================================================================
set -euo pipefail

# Git Bash (Windows) でネイティブ symlink を使うため
export MSYS=winsymlinks:nativestrict

HERE=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
ng()   { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
chk()  { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
head1() { echo; echo "=== $* ==============================================="; }

# --- root でない環境でも走るよう chown/chmod をスタブ -------------------------
mkdir -p "$SB/shim"
cat > "$SB/shim/chown" <<'SHIM'
#!/bin/sh
exit 0
SHIM
chmod +x "$SB/shim/chown"
export PATH="$SB/shim:$PATH"

# --- サンドボックス構築 -------------------------------------------------------
export SHARED_CONF_DIR="$SB/mnt/logs/tmp"
export DEFAULTS_DIR_BASE="$SB/opt/app/shared-conf/defaults"
mkdir -p "$SB/mnt/logs" "$SB/opt/app/shared-conf/bin"
cp "$HERE"/image/bin/*.sh "$SB/opt/app/shared-conf/bin/"
chmod +x "$SB"/opt/app/shared-conf/bin/*.sh

setup_container() {   # $1 = front|back , $2 = APP_ROOT , $3 = 初期値の中身
    local role="$1" root="$2" body="$3"
    mkdir -p "$root/servlets/jp/co/sample/base"
    printf '%s\n' "$body" > "$root/servlets/jp/co/sample/base/date_config.properties"
    mkdir -p "$SB/opt/$role"
    cp "$HERE/image/linkmap.conf" "$SB/opt/$role/linkmap.conf"
}

run_build() {         # $1 = role , $2 = APP_ROOT
    APP_ROOT="$2" \
    SHARED_CONF_DIR="$SHARED_CONF_DIR" \
    DEFAULTS_DIR="$DEFAULTS_DIR_BASE/$1" \
    SHARED_CONF_LINKMAP="$SB/opt/$1/linkmap.conf" \
    sh "$SB/opt/app/shared-conf/bin/build-shared-links.sh"
}

run_entrypoint() {    # $1 = role , $2 = APP_ROOT , 残り = 起動コマンド
    local role="$1" root="$2"; shift 2
    APP_ROOT="$root" \
    SHARED_CONF_DIR="$SHARED_CONF_DIR" \
    DEFAULTS_DIR="$DEFAULTS_DIR_BASE/$role" \
    SHARED_CONF_LINKMAP="$SB/opt/$role/linkmap.conf" \
    SHARED_CONF_WAIT=2 \
    sh "$SB/opt/app/shared-conf/bin/shared-conf-entrypoint.sh" "$@"
}

FRONT="$SB/webapp/webapp9mf02"
BACK="$SB/webapp/webapp9mb02"
LINK_F="$FRONT/servlets/jp/co/sample/base/date_config.properties"
LINK_B="$BACK/servlets/jp/co/sample/base/date_config.properties"
REAL="$SHARED_CONF_DIR/date_config.properties"

setup_container front "$FRONT" "date.format=yyyy/MM/dd"
setup_container back  "$BACK"  "date.format=yyyy/MM/dd"

head1 "1. ビルド時 (docker build 相当)"
run_build front "$FRONT" | sed 's/^/  | /'
run_build back  "$BACK"  | sed 's/^/  | /'
chk "front: LINK が symlink になった"           '[ -L "$LINK_F" ]'
chk "back : LINK が symlink になった"           '[ -L "$LINK_B" ]'
chk "front: リンク先が /mnt/logs/tmp/... "      '[ "$(readlink "$LINK_F")" = "$REAL" ]'
chk "back : リンク先が front と同一 (共有)"     '[ "$(readlink "$LINK_B")" = "$(readlink "$LINK_F")" ]'
chk "front: 初期値がイメージ内に退避された"     '[ -f "$DEFAULTS_DIR_BASE/front/servlets/jp/co/sample/base/date_config.properties" ]'
chk "EFS 未マウント時点ではリンクは dangling"   '[ ! -e "$LINK_F" ]'

head1 "2. 実行時 (front タスク初回起動)"
run_entrypoint front "$FRONT" true | sed 's/^/  | /'
chk "実体が EFS 上に生成された"                 '[ -f "$REAL" ]'
chk "front からリンク経由で読める"              '[ "$(cat "$LINK_F")" = "date.format=yyyy/MM/dd" ]'

head1 "3. 実行時 (back タスク起動 = 同じ実体を共有)"
run_entrypoint back "$BACK" true | sed 's/^/  | /'
chk "back からも同じ内容が読める"               '[ "$(cat "$LINK_B")" = "$(cat "$LINK_F")" ]'
chk "実体は1ファイルのみ"                       '[ "$(find "$SHARED_CONF_DIR" -type f | wc -l)" -eq 1 ]'

head1 "4. EC2 から編集 -> 全コンテナに反映"
printf '%s\n' "date.format=yyyy-MM-dd" "date.timezone=Asia/Tokyo" > "$REAL"
chk "front に編集が反映される"                  '[ "$(sed -n 1p "$LINK_F")" = "date.format=yyyy-MM-dd" ]'
chk "back  に編集が反映される"                  '[ "$(sed -n 2p "$LINK_B")" = "date.timezone=Asia/Tokyo" ]'

head1 "5. ECS タスク再起動 -> 編集内容が維持される"
run_entrypoint front "$FRONT" true | sed 's/^/  | /'
run_entrypoint back  "$BACK"  true | sed 's/^/  | /'
chk "再起動後も編集内容が残っている"            '[ "$(sed -n 1p "$REAL")" = "date.format=yyyy-MM-dd" ]'
chk "イメージ既定値で上書きされていない"        '[ "$(wc -l < "$REAL")" -eq 2 ]'

head1 "6. 8 コンテナ同時起動 (シード競合)"
rm -f "$REAL"
for i in 1 2 3 4; do
    run_entrypoint front "$FRONT" true >/dev/null 2>&1 &
    run_entrypoint back  "$BACK"  true >/dev/null 2>&1 &
done
wait
chk "同時起動後も実体は1ファイル"               '[ "$(find "$SHARED_CONF_DIR" -type f | wc -l)" -eq 1 ]'
chk "一時ファイルが残っていない"                '[ -z "$(find "$SHARED_CONF_DIR" -name ".seed.*" -print -quit)" ]'
chk "内容が初期値どおり"                        '[ "$(cat "$REAL")" = "date.format=yyyy/MM/dd" ]'

head1 "7. 異常系: 実体を消して STRICT=on / SEED=off なら起動失敗"
rm -f "$REAL"
set +e
SHARED_CONF_SEED=off run_entrypoint front "$FRONT" true >/dev/null 2>&1
rc=$?
set -e
chk "dangling リンクで entrypoint が非0終了"    '[ "$rc" -ne 0 ]'

echo
echo "========================================================"
echo " PASS=$PASS  FAIL=$FAIL"
echo "========================================================"
[ "$FAIL" -eq 0 ]
