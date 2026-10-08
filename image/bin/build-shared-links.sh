#!/bin/sh
# ============================================================================
# build-shared-links.sh  --  【ビルド時】に実行する。root で実行すること。
# ============================================================================
# readonlyRootFilesystem=true のため、/webapp 配下のシンボリックリンクは
# 実行時には作れない。よって「イメージに焼き込む」のがこのスクリプトの役目。
#
# ---- ビルドモード (SHARED_CONF_SYMLINK) ------------------------------------
#   off (既定) : symlink を作成しない = 各イメージが自前の実ファイルを持つ従来構成
#   on         : symlink を作成する = EFS 上の 1 ファイルを共有する構成
#
# on の場合、各エントリについて:
#   1) イメージ内の実体 (LINK の位置にある元ファイルまたは元ディレクトリ) を
#      DEFAULT に退避 -> 実行時の初回シード元になる
#   2) LINK を TARGET を指すシンボリックリンクに置き換える
#      -> ビルド時点では dangling (EFS 未マウント) だが、シンボリックリンクは
#        アクセス時に解決されるため実行時にマウントされていれば正しく解決される
#
#   1) の実体も DEFAULT も無い場合は、警告だけ出して 2) の symlink 作成を
#   続行する (シード元なしのビルド)。この構成では実体を EFS 側にあらかじめ
#   用意しておくこと (ec2/init-shared-conf.sh)。用意が無ければ実行時の
#   entrypoint が dangling を検出して起動を中止する。
#
# off の場合はイメージを一切書き換えない。linkmap の各 LINK が
# 「実ファイルまたは実ディレクトリとして存在するか」だけを検証する。
# 実行時の entrypoint も同じフラグを見て、EFS 待ち・シード・リンク検証を
# まとめてスキップする。
#
# ---- 追加機能 (SHARED_CONF_OVERLAY) ----------------------------------------
#   off (既定) : Deployment Overlays を使わない
#   on         : 実行時に jboss-cli.sh で配備済み WAR に設定ファイルを被せる
#
# overlay は完全に実行時の機構なので、ビルド時にイメージへ加える変更はない。
# ここでは「値が妥当か」と「実行時スクリプトが同梱されているか」だけを
# 検証して、タイプミスや COPY 漏れをビルド時に落とす。
# symlink とは独立しているので on/off の 4 通りすべて組み合わせられる。
#
# 使い方 (Dockerfile 内):
#   RUN APP_ROOT=/webapp/webapp9mf02 SHARED_CONF_SYMLINK=on SHARED_CONF_OVERLAY=on \
#         /opt/app/shared-conf/bin/build-shared-links.sh
# ============================================================================
set -eu

SC_TAG="shared-conf/build"
. "$(dirname "$0")/linkmap-lib.sh"

: "${APP_UID:=6301}"
: "${APP_GID:=6302}"
: "${DEFAULT_FILE_MODE:=0644}"
: "${SHARED_CONF_SYMLINK:=off}"
: "${SHARED_CONF_OVERLAY:=off}"

SHARED_CONF_SYMLINK=$(sc_flag SHARED_CONF_SYMLINK "${SHARED_CONF_SYMLINK}") || exit 1
SHARED_CONF_OVERLAY=$(sc_flag SHARED_CONF_OVERLAY "${SHARED_CONF_OVERLAY}") || exit 1

sc_log "APP_ROOT             = ${APP_ROOT}"
sc_log "SHARED_CONF_SYMLINK  = ${SHARED_CONF_SYMLINK}"
sc_log "SHARED_CONF_OVERLAY  = ${SHARED_CONF_OVERLAY}"
sc_log "SHARED_CONF_DIR      = ${SHARED_CONF_DIR}"
sc_log "DEFAULTS_DIR         = ${DEFAULTS_DIR}"
sc_log "linkmap              = ${SHARED_CONF_LINKMAP}"

# ===========================================================================
# SHARED_CONF_OVERLAY=on : 実行時スクリプトの同梱確認だけ行う
#   (実体の書き換えは実行時。ここでイメージには何もしない)
# ===========================================================================
if [ "${SHARED_CONF_OVERLAY}" = "on" ]; then
    _ovl_script="$(dirname "$0")/deployment-overlay.sh"
    if [ ! -f "${_ovl_script}" ]; then
        sc_err "SHARED_CONF_OVERLAY=on ですが ${_ovl_script} がありません。"
        sc_err "  Dockerfile に image/bin/deployment-overlay.sh の COPY を追加してください。"
        exit 1
    fi
    sc_log "Deployment Overlays は実行時に適用します (ビルド時のイメージ変更なし)"
    sc_log "  適用スクリプト: ${_ovl_script}"
else
    sc_log "Deployment Overlays は無効です (SHARED_CONF_OVERLAY=off)"
fi

# ===========================================================================
# SHARED_CONF_SYMLINK=off : 共有しない。イメージには手を入れない。
# ===========================================================================
_keep_one() {
    _link="$1"

    if [ -L "$_link" ]; then
        sc_err "既にシンボリックリンクです: ${_link} -> $(readlink "$_link")"
        sc_err "  SHARED_CONF_SYMLINK=off は「イメージ内の実ファイルを使う」ビルドです。"
        sc_err "  ベースイメージや先行ステージで symlink 化していないか確認してください。"
        return 1
    fi
    if [ ! -f "$_link" ] && [ ! -d "$_link" ]; then
        sc_err "実ファイル/ディレクトリが見つかりません: ${_link}"
        sc_err "  linkmap の LINK 列と APP_ROOT が正しいか、アプリ資材の COPY より"
        sc_err "  後ろでこのスクリプトを実行しているかを確認してください。"
        return 1
    fi

    if [ -d "$_link" ]; then
        sc_log "実ディレクトリのまま維持   : ${_link}"
    else
        sc_log "実ファイルのまま維持       : ${_link}"
    fi
    return 0
}

if [ "${SHARED_CONF_SYMLINK}" = "off" ]; then
    sc_log "symlink は作成しません (共有機構なしのイメージをビルドします)"
    if ! sc_each_entry _keep_one; then
        sc_err "対象ファイルの確認に失敗しました"
        exit 1
    fi
    sc_log "OK: 全エントリをイメージ内の実ファイルのまま維持しました (SHARED_CONF_SYMLINK=off)"
    exit 0
fi

# ===========================================================================
# SHARED_CONF_SYMLINK=on : 初期値を退避し、LINK を symlink に置き換える
# ===========================================================================
_build_one() {
    _link="$1"; _target="$2"; _default="$3"

    # ---- 1) 初期値(シード元)をイメージ内に確保 -----------------------------
    mkdir -p "$(dirname "$_default")"

    if [ -e "$_default" ] && [ ! -L "$_default" ]; then
        sc_log "default 既存のため流用      : ${_default}"
    elif [ -d "$_link" ] && [ ! -L "$_link" ]; then
        # ディレクトリに 0644 を付けると辿れなくなるので、モードは cp -a のまま残す
        cp -a "$_link" "$_default"
        sc_log "default をイメージから退避  : ${_link} -> ${_default} (directory)"
    elif [ -f "$_link" ] && [ ! -L "$_link" ]; then
        cp -p "$_link" "$_default"
        sc_log "default をイメージから退避  : ${_link} -> ${_default}"
    else
        # 実体も DEFAULT も無い場合はシード元なしとして扱い、
        # symlink の作成だけは続行する (実体は EFS 側で用意する運用)。
        sc_warn "シード元がありません (初期値なしで symlink だけ作成します): ${_link}"
        sc_warn "  実行時までに ${_target} を EFS 上に用意してください"
        sc_warn "  (ec2/init-shared-conf.sh 等)。イメージに初期値を持たせる場合は"
        sc_warn "  ${_default} を COPY してください。"
    fi

    if [ -d "$_default" ] && [ ! -L "$_default" ]; then
        chown -R "${APP_UID}:${APP_GID}" "$_default"
    elif [ -e "$_default" ]; then
        chown "${APP_UID}:${APP_GID}" "$_default"
        chmod "${DEFAULT_FILE_MODE}" "$_default"
    fi

    # ---- 2) LINK をシンボリックリンクに差し替え ----------------------------
    # rm -f はディレクトリを消せない (set -e でビルドが落ちる)。実ディレクトリだけ rm -rf。
    mkdir -p "$(dirname "$_link")"
    if [ -d "$_link" ] && [ ! -L "$_link" ]; then
        case "$_link" in
            /|""|/*/) sc_err "LINK が不正です (末尾 / や / は不可): ${_link}"; return 1 ;;
        esac
        rm -rf "$_link"
    else
        rm -f "$_link"
    fi
    ln -s "$_target" "$_link"
    chown -h "${APP_UID}:${APP_GID}" "$_link"

    sc_log "symlink 作成               : ${_link} -> ${_target}"
    return 0
}

if ! sc_each_entry _build_one; then
    sc_err "ビルド時リンク作成に失敗しました"
    exit 1
fi

# ---- 検証: 全リンクが symlink になっていて、想定 TARGET を指しているか ------
_verify_one() {
    _link="$1"; _target="$2"
    if [ ! -L "$_link" ]; then
        sc_err "symlink になっていません: ${_link}"
        return 1
    fi
    _actual=$(readlink "$_link")
    if [ "$_actual" != "$_target" ]; then
        sc_err "リンク先が不一致: ${_link} -> ${_actual} (期待: ${_target})"
        return 1
    fi
    return 0
}

if ! sc_each_entry _verify_one; then
    exit 1
fi

sc_log "OK: 全エントリのシンボリックリンクをイメージに焼き込みました"
