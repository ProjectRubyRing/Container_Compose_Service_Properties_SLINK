#!/usr/bin/env bash
# ============================================================================
# selftest-overlay.sh -- Deployment Overlays 機能の検証 (実 JBoss 不要)
# ============================================================================
# test/stub/jboss-cli.sh を偽 CLI として使い、deployment-overlay.sh が
# 実際に発行する管理コマンドと、その結果として登録される overlay を検証する。
#
# 検証内容:
#   1. 既定は off  : ビルドも実行時も何もしない (symlink / overlay 両方)
#   2. 配備内容の実測 : deployment browse-content でアーカイブ内パスを特定する
#   3. 同名ファイル : 複数の WAR に入っている同名ファイルを全部オーバレイする
#   4. 無関係な WAR : 対象ファイルを持たないデプロイメントには触らない
#   5. オーバレイ元 : EFS 上の実体 (symlink 先) の内容が使われる
#   6. 冪等性       : 2 回目は add ではなく upload + link + redeploy-affected
#   7. match=path   : 配備パス全体で照合するモード
#   8. browse=off   : browse を使わない場合のフォールバックと明示指定
#   9. 切り戻し     : remove で overlay が消える
#  10. 異常系       : CLI 失敗 / 不正値 / 対象ゼロ
#  11. entrypoint   : overlay=on のときバックグラウンドで適用される
#
# 使い方:  bash test/selftest-overlay.sh
# ============================================================================
set -uo pipefail

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
export SHARED_CONF_DIR="$SB/mnt/logs/tmp"
DEFAULTS_BASE="$SB/opt/app/shared-conf/defaults"
mkdir -p "$SB/mnt/logs" "$SB/opt/app/shared-conf/bin" "$SB/eap/bin" \
         "$SB/eap/standalone/configuration" "$SB/eap/standalone/data"
cp "$HERE"/image/bin/*.sh "$SB/opt/app/shared-conf/bin/"
cp "$HERE"/test/stub/jboss-cli.sh "$SB/eap/bin/jboss-cli.sh"
chmod +x "$SB"/opt/app/shared-conf/bin/*.sh "$SB/eap/bin/jboss-cli.sh"

REL="servlets/jp/co/sample/base/date_config.properties"
FRONT="$SB/webapp/webapp9mf02"
LINK_F="$FRONT/$REL"
REAL="$SHARED_CONF_DIR/date_config.properties"

mkdir -p "$FRONT/servlets/jp/co/sample/base" "$SB/opt/front"
printf '%s\n' "date.format=yyyy/MM/dd" > "$LINK_F"
cp "$HERE/image/linkmap.conf" "$SB/opt/front/linkmap.conf"

# --- 偽 JBoss の配備状況 ------------------------------------------------------
#   intra-web-front.war : WEB-INF/classes 配下に対象ファイルあり
#   common-lib.war      : 同名ファイルが別の場所にある (= 同名ファイルの一括対象)
#   exploded-app.war    : 展開ツリーと同じ相対パスで持っている (match=path 用)
#   other.war           : 対象ファイルを持たない
new_cli_state() {
    STUB="$SB/clistate.$1"
    rm -rf "$STUB"; mkdir -p "$STUB/content" "$STUB/overlays"
    printf '%s\n' intra-web-front.war common-lib.war exploded-app.war other.war > "$STUB/deployments"
    cat > "$STUB/content/intra-web-front.war.txt" <<'EOF'
META-INF/
META-INF/MANIFEST.MF
WEB-INF/
WEB-INF/web.xml
WEB-INF/classes/
WEB-INF/classes/jp/co/sample/base/date_config.properties
WEB-INF/classes/jp/co/sample/base/Foo.class
index.html
EOF
    cat > "$STUB/content/common-lib.war.txt" <<'EOF'
WEB-INF/
WEB-INF/classes/
WEB-INF/classes/date_config.properties
WEB-INF/lib/
EOF
    cat > "$STUB/content/exploded-app.war.txt" <<'EOF'
servlets/
servlets/jp/co/sample/base/date_config.properties
EOF
    cat > "$STUB/content/other.war.txt" <<'EOF'
WEB-INF/
WEB-INF/web.xml
EOF
    export STUB_STATE="$STUB"
}

run_build() {         # $1 = APP_ROOT , 残り = env
    env APP_ROOT="$1" \
        SHARED_CONF_DIR="$SHARED_CONF_DIR" \
        DEFAULTS_DIR="$DEFAULTS_BASE/front" \
        SHARED_CONF_LINKMAP="$SB/opt/front/linkmap.conf" \
        "${@:2}" \
        sh "$SB/opt/app/shared-conf/bin/build-shared-links.sh"
}

run_overlay() {       # $1 = subcommand , 残り = env=value
    local sub="$1"; shift
    env APP_ROOT="$FRONT" \
        SHARED_CONF_DIR="$SHARED_CONF_DIR" \
        DEFAULTS_DIR="$DEFAULTS_BASE/front" \
        SHARED_CONF_LINKMAP="$SB/opt/front/linkmap.conf" \
        JBOSS_HOME="$SB/eap" \
        STUB_STATE="$STUB_STATE" \
        SHARED_CONF_OVERLAY_INTERVAL=1 \
        SHARED_CONF_OVERLAY_WAIT=5 \
        "$@" \
        sh "$SB/opt/app/shared-conf/bin/deployment-overlay.sh" "$sub"
}

run_entrypoint() {    # 残り: env=value ... -- cmd...
    local envs=() ; while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
    env APP_ROOT="$FRONT" \
        SHARED_CONF_DIR="$SHARED_CONF_DIR" \
        DEFAULTS_DIR="$DEFAULTS_BASE/front" \
        SHARED_CONF_LINKMAP="$SB/opt/front/linkmap.conf" \
        JBOSS_HOME="$SB/eap" \
        STUB_STATE="$STUB_STATE" \
        SHARED_CONF_WAIT=2 \
        SHARED_CONF_OVERLAY_INTERVAL=1 \
        SHARED_CONF_OVERLAY_WAIT=5 \
        "${envs[@]}" \
        sh "$SB/opt/app/shared-conf/bin/shared-conf-entrypoint.sh" "$@"
}

# overlay 名からコンテンツ定義を引く (アーカイブ内パス=ローカルパス)
ovl() { cat "$STUB_STATE/overlays/$1.content" 2>/dev/null; }
lnk() { cat "$STUB_STATE/overlays/$1.links"   2>/dev/null; }

# ============================================================================
head1 "1. 既定値は off (symlink も overlay も作らない)"
new_cli_state default
run_build "$FRONT" >/dev/null 2>&1
chk "SHARED_CONF_SYMLINK 未指定 -> symlink を作らない" '[ ! -L "$LINK_F" ]'
chk "SHARED_CONF_SYMLINK 未指定 -> 実ファイルのまま"   '[ -f "$LINK_F" ]'
chk "SHARED_CONF_SYMLINK 未指定 -> defaults も作らない" '[ ! -e "$DEFAULTS_BASE/front" ]'

out=$(run_overlay apply 2>&1); rc=$?
chk "SHARED_CONF_OVERLAY 未指定 -> 正常終了する"       '[ "$rc" -eq 0 ]'
chk "SHARED_CONF_OVERLAY 未指定 -> CLI を1回も叩かない" '[ ! -s "$STUB_STATE/calls.log" ]'
chk "off である旨をログに出す"                         'echo "$out" | grep -q "SHARED_CONF_OVERLAY=off"'

# ============================================================================
head1 "2. ビルド: overlay=on はイメージを変更せず、同梱確認だけ行う"
new_cli_state build2
out=$(run_build "$FRONT" SHARED_CONF_OVERLAY=on 2>&1); rc=$?
chk "overlay=on でビルドが成功する"                    '[ "$rc" -eq 0 ]'
chk "overlay=on でも symlink は作られない (既定 off)"  '[ ! -L "$LINK_F" ]'
chk "deployment-overlay.sh の同梱を確認している"       'echo "$out" | grep -q "deployment-overlay.sh"'

rm -f "$SB/opt/app/shared-conf/bin/deployment-overlay.sh"
run_build "$FRONT" SHARED_CONF_OVERLAY=on >/dev/null 2>&1; rc=$?
chk "COPY 漏れならビルドが失敗する"                    '[ "$rc" -ne 0 ]'
cp "$HERE/image/bin/deployment-overlay.sh" "$SB/opt/app/shared-conf/bin/"
chmod +x "$SB/opt/app/shared-conf/bin/deployment-overlay.sh"

# ============================================================================
head1 "3. symlink=on でビルドし、EFS 上に実体を用意する"
new_cli_state main
run_build "$FRONT" SHARED_CONF_SYMLINK=on >/dev/null 2>&1
chk "symlink=on 指定なら symlink になる"               '[ -L "$LINK_F" ]'
mkdir -p "$SHARED_CONF_DIR"
printf '%s\n' "date.format=yyyy-MM-dd" "date.timezone=Asia/Tokyo" > "$REAL"
chk "EFS 上の実体をリンク経由で読める"                 '[ "$(sed -n 1p "$LINK_F")" = "date.format=yyyy-MM-dd" ]'

# ============================================================================
head1 "4. overlay 適用: browse-content で実際のアーカイブ内パスを特定する"
out=$(run_overlay apply SHARED_CONF_OVERLAY=on 2>&1); rc=$?
echo "$out" | sed 's/^/  | /'
chk "適用が成功する"                                    '[ "$rc" -eq 0 ]'
chk "browse-content を発行している"                     'grep -q "deployment browse-content --name=intra-web-front.war" "$STUB_STATE/calls.log"'
chk "WEB-INF/classes 配下の実パスを特定している" \
    '[ "$(ovl shared-conf-intra-web-front.war | cut -d= -f1)" = "WEB-INF/classes/jp/co/sample/base/date_config.properties" ]'
chk "オーバレイ元は EFS 上の実体" \
    '[ "$(ovl shared-conf-intra-web-front.war | cut -d= -f2-)" = "$REAL" ]'
chk "リンク先デプロイメントが正しい" \
    '[ "$(lnk shared-conf-intra-web-front.war)" = "intra-web-front.war" ]'

head1 "5. war として配備された同名ファイルも対象になる"
chk "common-lib.war にも overlay が作られる"            '[ -f "$STUB_STATE/overlays/shared-conf-common-lib.war.content" ]'
chk "common-lib.war 側の実パスを特定している" \
    '[ "$(ovl shared-conf-common-lib.war | cut -d= -f1)" = "WEB-INF/classes/date_config.properties" ]'
chk "exploded-app.war (展開形と同パス) も対象になる" \
    '[ "$(ovl shared-conf-exploded-app.war | cut -d= -f1)" = "servlets/jp/co/sample/base/date_config.properties" ]'
chk "対象ファイルを持たない other.war は触らない"       '[ ! -f "$STUB_STATE/overlays/shared-conf-other.war.content" ]'
chk "other.war をスキップした旨のログが出る"            'echo "$out" | grep -q "対象ファイルなし、スキップ: other.war"'
chk "3 デプロイメントに適用した旨のログが出る"          'echo "$out" | grep -q "OK: 3 個のデプロイメント"'

head1 "6. 適用時に redeploy される (--redeploy-affected)"
chk "intra-web-front.war が再デプロイ対象になっている"  'grep -qx "intra-web-front.war" "$STUB_STATE/redeploy.log"'
chk "other.war は再デプロイされない"                    '! grep -qx "other.war" "$STUB_STATE/redeploy.log"'

: > "$STUB_STATE/redeploy.log"
run_overlay apply SHARED_CONF_OVERLAY=on SHARED_CONF_OVERLAY_REDEPLOY=off >/dev/null 2>&1
chk "REDEPLOY=off なら再デプロイしない"                 '[ ! -s "$STUB_STATE/redeploy.log" ]'

# ============================================================================
head1 "7. 冪等性: 2 回目は add ではなく upload で内容を差し替える"
: > "$STUB_STATE/calls.log"
printf '%s\n' "date.format=yyyy.MM.dd" > "$REAL"
out=$(run_overlay apply SHARED_CONF_OVERLAY=on 2>&1); rc=$?
chk "2 回目も成功する"                                  '[ "$rc" -eq 0 ]'
chk "add は発行されない"                                '! grep -q "deployment-overlay add" "$STUB_STATE/calls.log"'
chk "upload が発行される"                               'grep -q "deployment-overlay upload --name=shared-conf-intra-web-front.war" "$STUB_STATE/calls.log"'
chk "redeploy-affected が発行される"                    'grep -q "deployment-overlay redeploy-affected" "$STUB_STATE/calls.log"'
chk "登録内容が重複していない"                          '[ "$(ovl shared-conf-intra-web-front.war | wc -l)" -eq 1 ]'
chk "リンクが重複していない"                            '[ "$(lnk shared-conf-intra-web-front.war | wc -l)" -eq 1 ]'
chk "編集後の内容が参照される (パスは同じ実体)"         '[ "$(cat "$REAL")" = "date.format=yyyy.MM.dd" ]'

# ============================================================================
head1 "8. match=path : 配備パス全体で照合する厳密モード"
new_cli_state matchpath
run_overlay apply SHARED_CONF_OVERLAY=on SHARED_CONF_OVERLAY_MATCH=path >/dev/null 2>&1
chk "展開形と同じ相対パスを持つ WAR だけが対象"         '[ -f "$STUB_STATE/overlays/shared-conf-exploded-app.war.content" ]'
chk "WEB-INF/classes 配下は対象外になる"                '[ ! -f "$STUB_STATE/overlays/shared-conf-intra-web-front.war.content" ]'
chk "別階層の同名ファイルも対象外になる"                '[ ! -f "$STUB_STATE/overlays/shared-conf-common-lib.war.content" ]'

# ============================================================================
head1 "9. browse=off : linkmap のパスにフォールバックする"
new_cli_state nobrowse
run_overlay apply SHARED_CONF_OVERLAY=on SHARED_CONF_OVERLAY_BROWSE=off \
            SHARED_CONF_OVERLAY_DEPLOYMENTS=intra-web-front.war >/dev/null 2>&1
chk "browse-content を発行しない"                       '! grep -q "browse-content" "$STUB_STATE/calls.log"'
chk "linkmap の相対パスがそのまま使われる" \
    '[ "$(ovl shared-conf-intra-web-front.war | cut -d= -f1)" = "'"$REL"'" ]'

head1 "10. linkmap 4 列目でアーカイブ内パスを明示する"
new_cli_state explicit
cat > "$SB/opt/front/linkmap-explicit.conf" <<'EOF'
${APP_ROOT}/servlets/jp/co/sample/base/date_config.properties  ${SHARED_CONF_DIR}/date_config.properties  -  WEB-INF/classes/jp/co/sample/base/date_config.properties
EOF
run_overlay apply SHARED_CONF_OVERLAY=on \
            SHARED_CONF_LINKMAP="$SB/opt/front/linkmap-explicit.conf" \
            SHARED_CONF_OVERLAY_DEPLOYMENTS=intra-web-front.war >/dev/null 2>&1
chk "明示したパスが使われる" \
    '[ "$(ovl shared-conf-intra-web-front.war | cut -d= -f1)" = "WEB-INF/classes/jp/co/sample/base/date_config.properties" ]'

cat > "$SB/opt/front/linkmap-abs.conf" <<'EOF'
${APP_ROOT}/servlets/jp/co/sample/base/date_config.properties  ${SHARED_CONF_DIR}/date_config.properties  -  /WEB-INF/classes/date_config.properties
EOF
run_overlay apply SHARED_CONF_OVERLAY=on \
            SHARED_CONF_LINKMAP="$SB/opt/front/linkmap-abs.conf" >/dev/null 2>&1; rc=$?
chk "4 列目に絶対パスを書くとエラーになる"              '[ "$rc" -ne 0 ]'

# ============================================================================
head1 "11. オーバレイ元の選択 (source)"
new_cli_state source
printf '%s\n' "from=EFS" > "$REAL"
run_overlay apply SHARED_CONF_OVERLAY=on SHARED_CONF_OVERLAY_SOURCE=target \
            SHARED_CONF_OVERLAY_DEPLOYMENTS=intra-web-front.war >/dev/null 2>&1
chk "source=target なら EFS 上の実体を使う" \
    '[ "$(ovl shared-conf-intra-web-front.war | cut -d= -f2-)" = "$REAL" ]'

new_cli_state source2
run_overlay apply SHARED_CONF_OVERLAY=on SHARED_CONF_OVERLAY_SOURCE=link \
            SHARED_CONF_OVERLAY_DEPLOYMENTS=intra-web-front.war >/dev/null 2>&1
chk "source=link ならイメージ内のパスを使う" \
    '[ "$(ovl shared-conf-intra-web-front.war | cut -d= -f2-)" = "$LINK_F" ]'

new_cli_state source3
mv "$REAL" "$SB/real.bak"
run_overlay apply SHARED_CONF_OVERLAY=on SHARED_CONF_OVERLAY_SOURCE=target \
            SHARED_CONF_OVERLAY_DEPLOYMENTS=intra-web-front.war >/dev/null 2>&1; rc=$?
chk "source=target で実体が無ければ失敗する"            '[ "$rc" -ne 0 ]'
mv "$SB/real.bak" "$REAL"

# ============================================================================
head1 "12. dry-run : 何も変更せずコマンドだけ見せる"
new_cli_state dryrun
out=$(run_overlay apply SHARED_CONF_OVERLAY=on SHARED_CONF_OVERLAY_DRYRUN=on 2>&1); rc=$?
chk "dry-run は成功する"                                '[ "$rc" -eq 0 ]'
chk "overlay は 1 つも作られない"                       '[ -z "$(ls -A "$STUB_STATE/overlays")" ]'
chk "発行予定のコマンドが表示される"                    'echo "$out" | grep -q "dry-run.*deployment-overlay add"'

# ============================================================================
head1 "13. status / browse / remove"
new_cli_state ops
run_overlay apply SHARED_CONF_OVERLAY=on >/dev/null 2>&1
out=$(run_overlay status SHARED_CONF_OVERLAY=on 2>&1)
chk "status に overlay 名が出る"                        'echo "$out" | grep -q "shared-conf-intra-web-front.war"'
chk "status に content が出る"                          'echo "$out" | grep -q "content | WEB-INF/classes"'

out=$(run_overlay browse SHARED_CONF_OVERLAY=off 2>&1)
chk "browse は overlay=off でも使える (調査用)"         'echo "$out" | grep -q "WEB-INF/classes/jp/co/sample/base/date_config.properties"'

run_overlay remove SHARED_CONF_OVERLAY=on >/dev/null 2>&1; rc=$?
chk "remove が成功する"                                 '[ "$rc" -eq 0 ]'
chk "overlay が全部消える"                              '[ -z "$(ls -A "$STUB_STATE/overlays")" ]'

# ============================================================================
head1 "14. 異常系"
new_cli_state err1
printf '%s\n' "deployment-overlay add" > "$STUB_STATE/fail-pattern"
run_overlay apply SHARED_CONF_OVERLAY=on >/dev/null 2>&1; rc=$?
chk "CLI が失敗したら非0で終わる"                       '[ "$rc" -ne 0 ]'

new_cli_state err2
printf '%s\n' "reload-required" > "$STUB_STATE/server-state"
run_overlay apply SHARED_CONF_OVERLAY=on >/dev/null 2>&1; rc=$?
chk "サーバが running にならなければ非0で終わる"        '[ "$rc" -ne 0 ]'

new_cli_state err3
printf '%s\n' nothing-here.war > "$STUB_STATE/deployments"
rm -f "$STUB_STATE/content/nothing-here.war.txt"
run_overlay apply SHARED_CONF_OVERLAY=on >/dev/null 2>&1; rc=$?
chk "対象が 1 つも無ければ非0で終わる"                  '[ "$rc" -ne 0 ]'

new_cli_state err4
run_overlay apply SHARED_CONF_OVERLAY=maybe >/dev/null 2>&1; rc=$?
chk "不正なフラグ値はエラーになる"                      '[ "$rc" -ne 0 ]'
run_overlay apply SHARED_CONF_OVERLAY=on SHARED_CONF_OVERLAY_MATCH=bogus >/dev/null 2>&1; rc=$?
chk "不正な列挙値 (match) はエラーになる"               '[ "$rc" -ne 0 ]'
run_overlay apply SHARED_CONF_OVERLAY=1 SHARED_CONF_OVERLAY_SOURCE=link \
            SHARED_CONF_OVERLAY_DEPLOYMENTS=intra-web-front.war >/dev/null 2>&1; rc=$?
chk "'1' は on として扱われる"                          '[ "$rc" -eq 0 ]'
run_overlay unknown-subcommand SHARED_CONF_OVERLAY=on >/dev/null 2>&1; rc=$?
chk "未知のサブコマンドはエラーになる"                  '[ "$rc" -ne 0 ]'

# ============================================================================
head1 "15. entrypoint 連携"
new_cli_state ep1
run_entrypoint SHARED_CONF_SYMLINK=on -- true >/dev/null 2>&1
chk "overlay=off なら entrypoint は CLI を叩かない"     '[ ! -s "$STUB_STATE/calls.log" ]'

new_cli_state ep2
out=$(run_entrypoint SHARED_CONF_SYMLINK=on SHARED_CONF_OVERLAY=on SHARED_CONF_OVERLAY_AUTO=off -- true 2>&1)
chk "OVERLAY_AUTO=off なら自動適用しない"               '[ ! -s "$STUB_STATE/calls.log" ]'
chk "手動適用の案内を出す"                              'echo "$out" | grep -q "手動適用"'

new_cli_state ep3
run_entrypoint SHARED_CONF_SYMLINK=on SHARED_CONF_OVERLAY=on -- sleep 1 >/dev/null 2>&1
for _ in $(seq 1 30); do
    [ -f "$STUB_STATE/overlays/shared-conf-intra-web-front.war.content" ] && break
    sleep 0.5
done
chk "entrypoint が起動コマンドを exec しつつ overlay を適用する" \
    '[ -f "$STUB_STATE/overlays/shared-conf-intra-web-front.war.content" ]'

new_cli_state ep4
touch "$SB/started"; rm -f "$SB/started"
run_entrypoint SHARED_CONF_SYMLINK=on SHARED_CONF_OVERLAY=on -- touch "$SB/started" >/dev/null 2>&1
chk "overlay=on でも本来の起動コマンドに exec される"   '[ -f "$SB/started" ]'

echo
echo "========================================================"
echo " PASS=$PASS  FAIL=$FAIL"
echo "========================================================"
[ "$FAIL" -eq 0 ]
