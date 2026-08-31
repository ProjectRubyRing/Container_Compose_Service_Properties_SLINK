# shellcheck shell=sh
# ============================================================================
# linkmap-lib.sh  --  linkmap.conf のパース処理 (POSIX sh / ビルド時・実行時 共通)
# ============================================================================
# このファイルは source されることを前提とする。単体実行はしない。
#
# 提供するもの:
#   sc_log / sc_warn / sc_err   : ログ出力
#   sc_expand <str>             : ${APP_ROOT} 等のトークン展開
#   sc_each_entry <callback>    : linkmap を1行ずつ読み、callback LINK TARGET DEFAULT を呼ぶ
#
# 必須環境変数 : APP_ROOT
# 任意環境変数 : SHARED_CONF_DIR (既定 /mnt/logs/tmp)
#                DEFAULTS_DIR    (既定 /opt/app/shared-conf/defaults)
#                SHARED_CONF_LINKMAP (既定 /opt/app/shared-conf/linkmap.conf)
# ============================================================================

SC_TAG="${SC_TAG:-shared-conf}"

sc_log()  { echo "[${SC_TAG}] $*"; }
sc_warn() { echo "[${SC_TAG}][WARN] $*" >&2; }
sc_err()  { echo "[${SC_TAG}][ERROR] $*" >&2; }

: "${SHARED_CONF_DIR:=/mnt/logs/tmp}"
: "${DEFAULTS_DIR:=/opt/app/shared-conf/defaults}"
: "${SHARED_CONF_LINKMAP:=/opt/app/shared-conf/linkmap.conf}"

# ---------------------------------------------------------------------------
# sc_expand <string>
#   eval を使わず、既知トークンのみを sed で置換する (linkmap に任意コードを
#   書けてしまう事故を防ぐため、意図的に eval を使わない)。
# ---------------------------------------------------------------------------
sc_expand() {
    printf '%s' "$1" | sed \
        -e "s|\${APP_ROOT}|${APP_ROOT}|g" \
        -e "s|\${SHARED_CONF_DIR}|${SHARED_CONF_DIR}|g" \
        -e "s|\${DEFAULTS_DIR}|${DEFAULTS_DIR}|g"
}

# ---------------------------------------------------------------------------
# sc_each_entry <callback>
#   linkmap を読み、各エントリについて  callback <LINK> <TARGET> <DEFAULT>  を呼ぶ。
#   callback が非0を返したら全体を非0で終了させるため sc_each_entry も非0を返す。
# ---------------------------------------------------------------------------
sc_each_entry() {
    _cb="$1"
    if [ ! -r "${SHARED_CONF_LINKMAP}" ]; then
        sc_err "linkmap が読めません: ${SHARED_CONF_LINKMAP}"
        return 1
    fi
    if [ -z "${APP_ROOT:-}" ]; then
        sc_err "APP_ROOT が未設定です"
        return 1
    fi

    _rc=0
    _lineno=0
    # 行末コメント除去 → 空行除去 の前処理を挟んでから読む
    while IFS= read -r _raw; do
        _lineno=$((_lineno + 1))
        _line=$(printf '%s' "$_raw" | sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "$_line" ] && continue

        # shellcheck disable=SC2086
        set -- $_line
        if [ "$#" -lt 2 ]; then
            sc_err "${SHARED_CONF_LINKMAP}:${_lineno}: 列が足りません (LINK と TARGET は必須): ${_line}"
            _rc=1
            continue
        fi

        _link=$(sc_expand "$1")
        _target=$(sc_expand "$2")
        _default=${3:--}

        if [ "$_default" = "-" ]; then
            # ${DEFAULTS_DIR} + (LINK から APP_ROOT を取り除いた相対パス)
            _rel=${_link#"${APP_ROOT}"}
            case "$_rel" in
                /*) : ;;
                *)  _rel="/$(basename "$_link")" ;;   # APP_ROOT 配下でない場合は basename
            esac
            _default="${DEFAULTS_DIR}${_rel}"
        else
            _default=$(sc_expand "$_default")
        fi

        _bad=
        for _p in "$_link" "$_target" "$_default"; do
            case "$_p" in
                /*) : ;;
                *)  _bad=1 ;;
            esac
        done
        if [ -n "$_bad" ]; then
            sc_err "${SHARED_CONF_LINKMAP}:${_lineno}: 絶対パスで指定してください: ${_line}"
            _rc=1
            continue
        fi

        if ! "$_cb" "$_link" "$_target" "$_default"; then
            _rc=1
        fi
    done < "${SHARED_CONF_LINKMAP}"

    return "$_rc"
}
