# shellcheck shell=sh
# ============================================================================
# linkmap-lib.sh  --  linkmap.conf のパース処理 (POSIX sh / ビルド時・実行時 共通)
# ============================================================================
# このファイルは source されることを前提とする。単体実行はしない。
#
# 提供するもの:
#   sc_log / sc_warn / sc_err   : ログ出力
#   sc_flag <名前> <値>         : on/off 系フラグの正規化 (true/1/yes なども受ける)
#   sc_enum <名前> <値> <候補…> : 列挙型パラメータの検証
#   sc_expand <str>             : ${APP_ROOT} 等のトークン展開
#   sc_rel_path <link>          : LINK から APP_ROOT を除いた相対パス (先頭 / なし)
#   sc_sanitize_name <str>      : 識別子として安全な文字列に変換
#   sc_each_entry <callback>    : linkmap を1行ずつ読み、
#                                 callback LINK TARGET DEFAULT OVERLAY_PATH を呼ぶ
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

# ---------------------------------------------------------------------------
# sc_flag <名前> <値>
#   on/off 系フラグを "on" / "off" に正規化して出力する。
#   docker の --build-arg やタスク定義の environment 経由で渡る値は
#   true/1/yes のように揺れやすいため、まとめてここで吸収する。
#   解釈できない値は設定ミスなので黙って off 扱いにせずエラーにする。
#
#   使い方:  FOO=$(sc_flag FOO "${FOO}") || exit 1
# ---------------------------------------------------------------------------
sc_flag() {
    case "$2" in
        on|On|ON|true|True|TRUE|yes|Yes|YES|1|enable|enabled)
            printf 'on' ;;
        off|Off|OFF|false|False|FALSE|no|No|NO|0|disable|disabled)
            printf 'off' ;;
        *)
            sc_err "$1 の値が不正です: '$2'  (on|off / true|false / 1|0 のいずれかを指定してください)"
            return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# sc_enum <名前> <値> <候補...>
#   列挙型のパラメータ (overlay の match/source など) を検証してそのまま出力する。
#   フラグ同様、タイプミスを黙って既定値に落とさずエラーにする。
#
#   使い方:  MODE=$(sc_enum MODE "${MODE}" name path) || exit 1
# ---------------------------------------------------------------------------
sc_enum() {
    _en_name="$1"; _en_val="$2"; shift 2
    for _en_c in "$@"; do
        if [ "$_en_val" = "$_en_c" ]; then
            printf '%s' "$_en_val"
            return 0
        fi
    done
    sc_err "${_en_name} の値が不正です: '${_en_val}'  (指定可能: $*)"
    return 1
}

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
# sc_rel_path <link>
#   LINK から APP_ROOT を取り除いた相対パス (先頭 '/' なし) を返す。
#   APP_ROOT 配下でない場合は basename を返す。
#   DEFAULT の自動決定と、Deployment Overlay のアーカイブ内パス既定値の
#   両方がこれを使う (= 同じ規則で決まる)。
# ---------------------------------------------------------------------------
sc_rel_path() {
    _rp=${1#"${APP_ROOT}"}
    case "$_rp" in
        /*) printf '%s' "${_rp#/}" ;;
        *)  basename "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# sc_sanitize_name <string>
#   deployment 名などを、識別子として安全な文字だけに落とす
#   ([A-Za-z0-9._-] 以外を '_' に置換)。overlay 名の生成に使う。
# ---------------------------------------------------------------------------
sc_sanitize_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# ---------------------------------------------------------------------------
# sc_each_entry <callback>
#   linkmap を読み、各エントリについて
#     callback <LINK> <TARGET> <DEFAULT> <OVERLAY_PATH>
#   を呼ぶ。OVERLAY_PATH は 4 列目 (省略/'-' なら '-' のまま渡す。
#   実際のアーカイブ内パスの決定は deployment-overlay.sh 側の責務)。
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
        _ovlpath=${4:--}

        if [ "$_default" = "-" ]; then
            # ${DEFAULTS_DIR} + (LINK から APP_ROOT を取り除いた相対パス)
            _default="${DEFAULTS_DIR}/$(sc_rel_path "$_link")"
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

        # OVERLAY_PATH は「アーカイブ内の相対パス」なので絶対パスは誤り
        case "$_ovlpath" in
            /*)
                sc_err "${SHARED_CONF_LINKMAP}:${_lineno}: OVERLAY_PATH (4列目) はアーカイブ内の相対パスです。先頭の '/' を外してください: ${_ovlpath}"
                _rc=1
                continue ;;
        esac

        if ! "$_cb" "$_link" "$_target" "$_default" "$_ovlpath"; then
            _rc=1
        fi
    done < "${SHARED_CONF_LINKMAP}"

    return "$_rc"
}
