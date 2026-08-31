#!/bin/sh
# ============================================================================
# build-shared-links.sh  --  【ビルド時】に実行する。root で実行すること。
# ============================================================================
# readonlyRootFilesystem=true のため、/webapp 配下のシンボリックリンクは
# 実行時には作れない。よって「イメージに焼き込む」のがこのスクリプトの役目。
#
# 各エントリについて:
#   1) イメージ内の実ファイル (LINK の位置にある元ファイル) を DEFAULT に退避
#      → 実行時の初回シード元になる
#   2) LINK を TARGET を指すシンボリックリンクに置き換える
#      → ビルド時点では dangling (EFS 未マウント) だが、シンボリックリンクは
#        アクセス時に解決されるため実行時にマウントされていれば正しく解決される
#
# 使い方 (Dockerfile 内):
#   RUN APP_ROOT=/webapp/webapp9mf02 /opt/app/shared-conf/bin/build-shared-links.sh
# ============================================================================
set -eu

SC_TAG="shared-conf/build"
. "$(dirname "$0")/linkmap-lib.sh"

: "${APP_UID:=6301}"
: "${APP_GID:=6302}"
: "${DEFAULT_FILE_MODE:=0644}"

sc_log "APP_ROOT        = ${APP_ROOT}"
sc_log "SHARED_CONF_DIR = ${SHARED_CONF_DIR}"
sc_log "DEFAULTS_DIR    = ${DEFAULTS_DIR}"
sc_log "linkmap         = ${SHARED_CONF_LINKMAP}"

_build_one() {
    _link="$1"; _target="$2"; _default="$3"

    # ---- 1) 初期値(シード元)をイメージ内に確保 -----------------------------
    mkdir -p "$(dirname "$_default")"

    if [ -e "$_default" ] && [ ! -L "$_default" ]; then
        sc_log "default 既存のため流用      : ${_default}"
    elif [ -f "$_link" ] && [ ! -L "$_link" ]; then
        cp -p "$_link" "$_default"
        sc_log "default をイメージから退避  : ${_link} -> ${_default}"
    else
        sc_err "シード元が見つかりません。${_link} が実ファイルとして存在しないなら"
        sc_err "  ${_default} を COPY で用意してください。"
        return 1
    fi

    chown "${APP_UID}:${APP_GID}" "$_default"
    chmod "${DEFAULT_FILE_MODE}" "$_default"

    # ---- 2) LINK をシンボリックリンクに差し替え ----------------------------
    mkdir -p "$(dirname "$_link")"
    rm -f "$_link"
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
