#!/usr/bin/env bash
# ============================================================================
# selftest-dir.sh -- ディレクトリのシンボリックリンク共有
# ============================================================================
# 検証内容:
#   1. ビルド時: ディレクトリが symlink になり、中身は defaults に退避される
#   2. 実行時 : EFS 上にディレクトリ実体が初回だけ作られ、front/back で共有される
#   3. 編集   : 配下ファイルの変更・追加が再起動後も残る
#   4. 並行   : 同時起動しても実体は 1 ディレクトリ / 一時ディレクトリが残らない
#   5. off    : ディレクトリは実ディレクトリのまま (EFS 不要)
#   6. 混在   : 同じ linkmap のファイルエントリは従来どおり
#   7. overlay: ディレクトリはスキップし、ファイルだけ overlay する
#
# 使い方:  bash test/selftest-dir.sh
# ============================================================================
set -euo pipefail

export MSYS=winsymlinks:nativestrict

HERE=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
ng()   { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
chk()  { if eval "$2"; then ok "$1"; else ng "$1"; fi; }
head1() { echo; echo "=== $* ==============================================="; }

mkdir -p "$SB/shim"
printf '#!/bin/sh\nexit 0\n' > "$SB/shim/chown"
chmod +x "$SB/shim/chown"
export PATH="$SB/shim:$PATH"

export SHARED_CONF_DIR="$SB/mnt/logs/tmp"
export DEFAULTS_DIR_BASE="$SB/opt/app/shared-conf/defaults"
mkdir -p "$SB/mnt/logs" "$SB/opt/app/shared-conf/bin" "$SB/eap/bin"
cp "$HERE"/image/bin/*.sh "$SB/opt/app/shared-conf/bin/"
cp "$HERE"/test/stub/jboss-cli.sh "$SB/eap/bin/jboss-cli.sh"
chmod +x "$SB"/opt/app/shared-conf/bin/*.sh "$SB/eap/bin/jboss-cli.sh"

CONF_REL="servlets/jp/co/sample/conf"
FILE_REL="servlets/jp/co/sample/base/date_config.properties"

write_linkmap() {   # $1 = dest
    cat > "$1" <<'EOF'
${APP_ROOT}/servlets/jp/co/sample/conf  ${SHARED_CONF_DIR}/conf  -  -
${APP_ROOT}/servlets/jp/co/sample/base/date_config.properties  ${SHARED_CONF_DIR}/date_config.properties  -  -
EOF
}

seed_tree() {   # $1 = APP_ROOT
    mkdir -p "$1/${CONF_REL}/nested"
    printf '%s\n' "key=from-image" > "$1/${CONF_REL}/app.properties"
    printf '%s\n' "extra" > "$1/${CONF_REL}/nested/extra.txt"
    ln -s extra.txt "$1/${CONF_REL}/nested/link.txt"
    mkdir -p "$1/servlets/jp/co/sample/base"
    printf '%s\n' "date.format=yyyy/MM/dd" > "$1/${FILE_REL}"
}

setup_role() {  # $1 = role , $2 = APP_ROOT
    seed_tree "$2"
    mkdir -p "$SB/opt/$1"
    write_linkmap "$SB/opt/$1/linkmap.conf"
}

run_build() {   # $1 = role , $2 = APP_ROOT , $3 = symlink flag
    APP_ROOT="$2" \
    SHARED_CONF_SYMLINK="$3" \
    SHARED_CONF_DIR="$SHARED_CONF_DIR" \
    DEFAULTS_DIR="$DEFAULTS_DIR_BASE/$1" \
    SHARED_CONF_LINKMAP="$SB/opt/$1/linkmap.conf" \
    sh "$SB/opt/app/shared-conf/bin/build-shared-links.sh"
}

run_entrypoint() {  # $1 = role , $2 = APP_ROOT , $3 = symlink flag , rest = cmd
    local role="$1" root="$2" flag="$3"; shift 3
    APP_ROOT="$root" \
    SHARED_CONF_SYMLINK="$flag" \
    SHARED_CONF_DIR="$SHARED_CONF_DIR" \
    DEFAULTS_DIR="$DEFAULTS_DIR_BASE/$role" \
    SHARED_CONF_LINKMAP="$SB/opt/$role/linkmap.conf" \
    SHARED_CONF_WAIT=2 \
    sh "$SB/opt/app/shared-conf/bin/shared-conf-entrypoint.sh" "$@"
}

FRONT="$SB/webapp/webapp9mf02"
BACK="$SB/webapp/webapp9mb02"
LINK_DF="$FRONT/$CONF_REL"
LINK_DB="$BACK/$CONF_REL"
LINK_FF="$FRONT/$FILE_REL"
REAL_D="$SHARED_CONF_DIR/conf"
REAL_F="$SHARED_CONF_DIR/date_config.properties"
DEF_D="$DEFAULTS_DIR_BASE/front/$CONF_REL"

setup_role front "$FRONT"
setup_role back  "$BACK"

head1 "1. ビルド時 (ディレクトリ + ファイル)"
run_build front "$FRONT" on | sed 's/^/  | /'
run_build back  "$BACK"  on >/dev/null
chk "front: ディレクトリ LINK が symlink"        '[ -L "$LINK_DF" ]'
chk "front: 解決先はディレクトリ扱いのパス"      '[ "$(readlink "$LINK_DF")" = "$REAL_D" ]'
chk "back : 同じディレクトリを指す"              '[ "$(readlink "$LINK_DB")" = "$REAL_D" ]'
chk "front: ファイル LINK も従来どおり symlink"  '[ -L "$LINK_FF" ] && [ "$(readlink "$LINK_FF")" = "$REAL_F" ]'
chk "defaults にディレクトリツリーが退避された"  '[ -f "$DEF_D/app.properties" ] && [ -f "$DEF_D/nested/extra.txt" ]'
chk "defaults 内の相対 symlink が残っている"     '[ -L "$DEF_D/nested/link.txt" ] && [ "$(readlink "$DEF_D/nested/link.txt")" = "extra.txt" ]'
chk "ディレクトリに 0644 を付けていない"         '[ -x "$DEF_D" ] && [ -x "$DEF_D/nested" ]'
chk "EFS 未作成時点ではディレクトリリンクは dangling" '[ ! -e "$LINK_DF" ]'

head1 "2. 実行時シードと共有"
run_entrypoint front "$FRONT" on true | sed 's/^/  | /'
chk "EFS 上にディレクトリ実体ができた"           '[ -d "$REAL_D" ] && [ ! -L "$REAL_D" ]'
chk "配下ファイルが読める"                       '[ "$(cat "$LINK_DF/app.properties")" = "key=from-image" ]'
chk "配下の相対 symlink が解決する"              '[ "$(cat "$LINK_DF/nested/link.txt")" = "extra" ]'
chk "ファイル実体も同時にできた"                 '[ "$(cat "$LINK_FF")" = "date.format=yyyy/MM/dd" ]'
run_entrypoint back "$BACK" on true >/dev/null
chk "back も同じディレクトリを読む"              '[ "$(cat "$LINK_DB/app.properties")" = "key=from-image" ]'
chk "実ディレクトリは 1 つ"                      '[ "$(find "$SHARED_CONF_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]'

head1 "3. 編集と再起動"
printf '%s\n' "key=edited" > "$REAL_D/app.properties"
printf '%s\n' "new" > "$REAL_D/nested/new.txt"
chk "front に編集が見える"                       '[ "$(cat "$LINK_DF/app.properties")" = "key=edited" ]'
chk "back から追加ファイルが見える"              '[ "$(cat "$LINK_DB/nested/new.txt")" = "new" ]'
run_entrypoint front "$FRONT" on true >/dev/null
run_entrypoint back  "$BACK"  on true >/dev/null
chk "再起動でディレクトリ内容が戻らない"         '[ "$(cat "$REAL_D/app.properties")" = "key=edited" ] && [ -f "$REAL_D/nested/new.txt" ]'

head1 "4. 同時起動"
rm -rf "$REAL_D" "$REAL_F"
for i in 1 2 3 4; do
    run_entrypoint front "$FRONT" on true >/dev/null 2>&1 &
    run_entrypoint back  "$BACK"  on true >/dev/null 2>&1 &
done
wait
chk "同時起動後も実ディレクトリは 1 つ"          '[ -d "$REAL_D" ] && [ "$(find "$SHARED_CONF_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]'
chk "一時ディレクトリが残っていない"             '[ -z "$(find "$SHARED_CONF_DIR" -name ".seed.*" -print -quit)" ]'
chk "同時起動後の内容が初期値"                   '[ "$(cat "$REAL_D/app.properties")" = "key=from-image" ] && [ "$(cat "$REAL_D/nested/link.txt")" = "extra" ]'
chk "ファイル側も 1 つ"                          '[ -f "$REAL_F" ] && [ "$(find "$SHARED_CONF_DIR" -type f -name "date_config.properties" | wc -l)" -eq 1 ]'

head1 "5. SYMLINK=off は実ディレクトリのまま"
OFF="$SB/webapp/off"
setup_role off "$OFF"
run_build off "$OFF" off >/dev/null
chk "off: symlink になっていない"                '[ ! -L "$OFF/$CONF_REL" ] && [ -d "$OFF/$CONF_REL" ]'
chk "off: 中身が残っている"                      '[ "$(cat "$OFF/$CONF_REL/app.properties")" = "key=from-image" ]'
# EFS ディレクトリを消して「EFS が無い」状態にする
rm -rf "$SHARED_CONF_DIR"
run_entrypoint off "$OFF" off true >/dev/null
chk "off: EFS なしで起動できる"                  '[ -d "$OFF/$CONF_REL" ] && [ ! -d "$SHARED_CONF_DIR" ]'

head1 "6. 実体なし + SEED=off は起動失敗"
rm -rf "$REAL_D"
set +e
SHARED_CONF_SEED=off run_entrypoint front "$FRONT" on true >/dev/null 2>&1
rc=$?
set -e
chk "dangling ディレクトリで entrypoint が非0"   '[ "$rc" -ne 0 ]'

head1 "7. overlay はディレクトリをスキップしファイルだけ適用"
# 6 で消した実体を戻す
run_entrypoint front "$FRONT" on true >/dev/null
STUB="$SB/clistate"
rm -rf "$STUB"; mkdir -p "$STUB/content" "$STUB/overlays"
printf '%s\n' intra-web-front.war > "$STUB/deployments"
cat > "$STUB/content/intra-web-front.war.txt" <<'EOF'
WEB-INF/
WEB-INF/classes/
WEB-INF/classes/jp/co/sample/base/date_config.properties
EOF
export STUB_STATE="$STUB"
set +e
out=$(APP_ROOT="$FRONT" \
    SHARED_CONF_OVERLAY=on \
    SHARED_CONF_DIR="$SHARED_CONF_DIR" \
    DEFAULTS_DIR="$DEFAULTS_DIR_BASE/front" \
    SHARED_CONF_LINKMAP="$SB/opt/front/linkmap.conf" \
    JBOSS_HOME="$SB/eap" \
    STUB_STATE="$STUB" \
    SHARED_CONF_OVERLAY_INTERVAL=1 \
    SHARED_CONF_OVERLAY_WAIT=5 \
    sh "$SB/opt/app/shared-conf/bin/deployment-overlay.sh" apply 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | sed 's/^/  | /'
chk "overlay 適用が成功する"                     '[ "$rc" -eq 0 ]'
chk "ディレクトリは overlay 対象外とログに出る"  'printf "%s\n" "$out" | grep -q "ディレクトリのため overlay 対象外"'
chk "ファイルのオーバレイ元は出る"               'printf "%s\n" "$out" | grep -q "date_config.properties"'
chk "overlay 内容に conf ディレクトリは無い"     '! grep -q "/conf" "$STUB/overlays/"*.content'

head1 "8. EC2 init の --seed でディレクトリを配置できる"
if [ "$(id -u)" -eq 0 ]; then
    SEED="$SB/seed/conf"
    mkdir -p "$SEED/nested"
    printf '%s\n' "key=from-ec2" > "$SEED/app.properties"
    SKIP_MOUNT_CHECK=1 bash "$HERE/ec2/init-shared-conf.sh" \
        --dir "$SB/ec2efs" --seed "$SEED" >/dev/null
    chk "init がディレクトリを配置する"          '[ "$(cat "$SB/ec2efs/conf/app.properties")" = "key=from-ec2" ]'
    printf '%s\n' "key=keep" > "$SB/ec2efs/conf/app.properties"
    SKIP_MOUNT_CHECK=1 bash "$HERE/ec2/init-shared-conf.sh" \
        --dir "$SB/ec2efs" --seed "$SEED" >/dev/null
    chk "2 回目の init は既存ディレクトリを上書きしない" '[ "$(cat "$SB/ec2efs/conf/app.properties")" = "key=keep" ]'
else
    ok "init のディレクトリ配置は root 以外ではスキップ (chown が必要なため)"
fi

echo
echo "========================================================"
echo " PASS=$PASS  FAIL=$FAIL"
echo "========================================================"
[ "$FAIL" -eq 0 ]
