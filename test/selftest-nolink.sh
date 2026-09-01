#!/usr/bin/env bash
# ============================================================================
# selftest-nolink.sh -- ビルド引数 SHARED_CONF_SYMLINK による処理分岐の検証
# ============================================================================
# 検証内容:
#   1. off ビルド: symlink を作らず、イメージ内の実ファイルがそのまま残る
#   2. off 実行時: EFS が無くても起動でき、EFS 上に何も作らない
#   3. off の帰結: front / back の設定は共有されない (各イメージが独立)
#   4. 取り違え検知: ビルド時と実行時でフラグが食い違えば起動を中止する
#   5. フラグ解釈: true/1/no などの表記揺れを吸収し、不正値はエラーにする
#   6. 既定値    : SHARED_CONF_SYMLINK 未指定なら off として扱われる
#
# 使い方:  bash test/selftest-nolink.sh
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

# --- root でない環境でも走るよう chown をスタブ -------------------------------
mkdir -p "$SB/shim"
printf '#!/bin/sh\nexit 0\n' > "$SB/shim/chown"
chmod +x "$SB/shim/chown"
export PATH="$SB/shim:$PATH"

# --- サンドボックス構築 -------------------------------------------------------
# SHARED_CONF_DIR は「EFS が未マウントのまま」を再現するため作らない。
export SHARED_CONF_DIR="$SB/mnt/logs/tmp"
export DEFAULTS_DIR_BASE="$SB/opt/app/shared-conf/defaults"
mkdir -p "$SB/opt/app/shared-conf/bin"
cp "$HERE"/image/bin/*.sh "$SB/opt/app/shared-conf/bin/"
chmod +x "$SB"/opt/app/shared-conf/bin/*.sh

REL="servlets/jp/co/sample/base/date_config.properties"

setup_container() {   # $1 = tag , $2 = APP_ROOT , $3 = 初期値の中身
    local tag="$1" root="$2" body="$3"
    mkdir -p "$root/servlets/jp/co/sample/base"
    printf '%s\n' "$body" > "$root/$REL"
    mkdir -p "$SB/opt/$tag"
    cp "$HERE/image/linkmap.conf" "$SB/opt/$tag/linkmap.conf"
}

run_build() {         # $1 = tag , $2 = APP_ROOT , $3 = SHARED_CONF_SYMLINK
    APP_ROOT="$2" \
    SHARED_CONF_SYMLINK="$3" \
    SHARED_CONF_DIR="$SHARED_CONF_DIR" \
    DEFAULTS_DIR="$DEFAULTS_DIR_BASE/$1" \
    SHARED_CONF_LINKMAP="$SB/opt/$1/linkmap.conf" \
    sh "$SB/opt/app/shared-conf/bin/build-shared-links.sh"
}

run_entrypoint() {    # $1 = tag , $2 = APP_ROOT , $3 = SHARED_CONF_SYMLINK , 残り = 起動コマンド
    local tag="$1" root="$2" flag="$3"; shift 3
    APP_ROOT="$root" \
    SHARED_CONF_SYMLINK="$flag" \
    SHARED_CONF_DIR="$SHARED_CONF_DIR" \
    DEFAULTS_DIR="$DEFAULTS_DIR_BASE/$tag" \
    SHARED_CONF_LINKMAP="$SB/opt/$tag/linkmap.conf" \
    SHARED_CONF_WAIT=2 \
    sh "$SB/opt/app/shared-conf/bin/shared-conf-entrypoint.sh" "$@"
}

FRONT="$SB/webapp/webapp9mf02"
BACK="$SB/webapp/webapp9mb02"
LINK_F="$FRONT/$REL"
LINK_B="$BACK/$REL"

setup_container front "$FRONT" "date.format=yyyy/MM/dd"
setup_container back  "$BACK"  "date.format=yyyy/MM/dd"

head1 "1. ビルド時 (--build-arg SHARED_CONF_SYMLINK=off)"
run_build front "$FRONT" off | sed 's/^/  | /'
run_build back  "$BACK"  off | sed 's/^/  | /'
chk "front: symlink になっていない"             '[ ! -L "$LINK_F" ]'
chk "front: 実ファイルのまま残っている"         '[ -f "$LINK_F" ]'
chk "front: 内容が書き換えられていない"         '[ "$(cat "$LINK_F")" = "date.format=yyyy/MM/dd" ]'
chk "front: defaults への退避も行われない"      '[ ! -e "$DEFAULTS_DIR_BASE/front" ]'
chk "back : symlink になっていない"             '[ ! -L "$LINK_B" ]'

head1 "2. 実行時 (EFS が無くても起動できる)"
set +e
run_entrypoint front "$FRONT" off touch "$SB/started-front" | sed 's/^/  | /'
rc_front=${PIPESTATUS[0]}
set -e
chk "entrypoint が正常終了する"                 '[ "$rc_front" -eq 0 ]'
chk "本来の起動コマンドに exec されている"      '[ -f "$SB/started-front" ]'
chk "EFS 側には何も作られていない"              '[ ! -d "$SHARED_CONF_DIR" ]'
chk "アプリからはイメージ内の実ファイルが読める" '[ "$(cat "$LINK_F")" = "date.format=yyyy/MM/dd" ]'

head1 "3. off の帰結: front / back は共有されない"
printf '%s\n' "date.format=FRONT-ONLY" > "$LINK_F"
chk "front だけが変わる"                        '[ "$(cat "$LINK_F")" = "date.format=FRONT-ONLY" ]'
chk "back は元のまま (共有されない)"            '[ "$(cat "$LINK_B")" = "date.format=yyyy/MM/dd" ]'

head1 "4. 取り違え検知 (ビルド時と実行時でフラグが食い違う)"
setup_container on-built "$SB/webapp/on-built" "date.format=yyyy/MM/dd"
run_build on-built "$SB/webapp/on-built" on >/dev/null
set +e
run_entrypoint on-built "$SB/webapp/on-built" off true >/dev/null 2>&1
rc_mix1=$?
run_entrypoint front "$FRONT" on true >/dev/null 2>&1
rc_mix2=$?
set -e
chk "on ビルドのイメージを off で起動 -> 中止"  '[ "$rc_mix1" -ne 0 ]'
chk "off ビルドのイメージを on で起動 -> 中止"  '[ "$rc_mix2" -ne 0 ]'

head1 "5. フラグの表記揺れ / 不正値"
setup_container flag-false "$SB/webapp/flag-false" "x=1"
setup_container flag-one   "$SB/webapp/flag-one"   "x=1"
setup_container flag-bad   "$SB/webapp/flag-bad"   "x=1"
run_build flag-false "$SB/webapp/flag-false" false >/dev/null
run_build flag-one   "$SB/webapp/flag-one"   1     >/dev/null
set +e
run_build flag-bad "$SB/webapp/flag-bad" maybe >/dev/null 2>&1
rc_bad=$?
set -e
chk "false は off として扱われる"               '[ ! -L "$SB/webapp/flag-false/$REL" ]'
chk "1 は on として扱われる"                    '[ -L "$SB/webapp/flag-one/$REL" ]'
chk "不正値 (maybe) はビルドを失敗させる"       '[ "$rc_bad" -ne 0 ]'
chk "不正値のときイメージは書き換えられない"    '[ ! -L "$SB/webapp/flag-bad/$REL" ]'

head1 "5b. 未指定時の既定値は off"
# 先行するテストが $SHARED_CONF_DIR を作ってしまっているので、
# 「EFS に触れない」ことを見るために専用の未作成ディレクトリを使う。
NONE_DIR="$SB/mnt/logs-none/tmp"
setup_container flag-none "$SB/webapp/flag-none" "x=1"
APP_ROOT="$SB/webapp/flag-none" \
SHARED_CONF_DIR="$NONE_DIR" \
DEFAULTS_DIR="$DEFAULTS_DIR_BASE/flag-none" \
SHARED_CONF_LINKMAP="$SB/opt/flag-none/linkmap.conf" \
sh "$SB/opt/app/shared-conf/bin/build-shared-links.sh" >/dev/null 2>&1
set +e
APP_ROOT="$SB/webapp/flag-none" \
SHARED_CONF_DIR="$NONE_DIR" \
DEFAULTS_DIR="$DEFAULTS_DIR_BASE/flag-none" \
SHARED_CONF_LINKMAP="$SB/opt/flag-none/linkmap.conf" \
SHARED_CONF_WAIT=2 \
sh "$SB/opt/app/shared-conf/bin/shared-conf-entrypoint.sh" true >/dev/null 2>&1
rc_none=$?
set -e
chk "ビルド: 未指定なら symlink を作らない"     '[ ! -L "$SB/webapp/flag-none/$REL" ]'
chk "ビルド: 未指定なら defaults も作らない"    '[ ! -e "$DEFAULTS_DIR_BASE/flag-none" ]'
chk "実行時: 未指定でも EFS に触れず起動する"   '[ "$rc_none" -eq 0 ]'
chk "実行時: 未指定なら EFS 側に何も作らない"   '[ ! -d "$NONE_DIR" ]'

head1 "6. 異常系: 対象ファイルが無いのに off ビルド"
setup_container missing "$SB/webapp/missing" "x=1"
rm -f "$SB/webapp/missing/$REL"
set +e
run_build missing "$SB/webapp/missing" off >/dev/null 2>&1
rc_missing=$?
set -e
chk "実ファイルが無ければビルドが失敗する"      '[ "$rc_missing" -ne 0 ]'

echo
echo "========================================================"
echo " PASS=$PASS  FAIL=$FAIL"
echo "========================================================"
[ "$FAIL" -eq 0 ]
