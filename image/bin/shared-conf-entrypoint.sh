#!/bin/sh
# ============================================================================
# shared-conf-entrypoint.sh  --  【実行時】entrypoint ラッパ。appuser(6301) で実行。
# ============================================================================
# 役割は「アプリが読む設定ファイルの実体を用意すること」だけ。
# /webapp 配下 (readonlyRootFilesystem=true) には一切書き込まない。
#
# 独立した 2 つの機構をビルド引数で個別に on/off できる。
#
#   SHARED_CONF_SYMLINK  (既定 off)
#     イメージ内のファイルを EFS 上の1ファイルへの symlink に置換する機構。
#     on のとき、この entrypoint は
#       1) ${SHARED_CONF_DIR} が使えることを確認 (EFS マウント待ち)
#       2) 実体が「存在しない場合のみ」初期値から生成 (アトミック)
#          -> 既存は絶対に上書きしない = ECS タスク再起動でも内容が維持される
#       3) 各シンボリックリンクが実際に解決できることを検証 (fail fast)
#     を行う。off のときは対象がイメージ内の実ファイルであることだけ確認する。
#
#   SHARED_CONF_OVERLAY  (既定 off)
#     JBoss EAP の Deployment Overlays で、配備済み WAR アーカイブを
#     書き換えずに同じファイルを上書きする機構 (deployment-overlay.sh)。
#     on のとき、サーバ起動後にバックグラウンドで jboss-cli.sh を叩く。
#     symlink=on/off のどちらとも組み合わせられる。
#
# 最後に exec で本来のプロセス (JBoss EAP の起動コマンド) に引き継ぐ。
#
# Dockerfile:
#   ENTRYPOINT ["/opt/app/shared-conf/bin/shared-conf-entrypoint.sh"]
#   CMD ["/opt/eap/bin/standalone.sh", "-b", "0.0.0.0", "-bmanagement", "0.0.0.0"]
#
# 環境変数:
#   APP_ROOT             必須 (/webapp/webapp9mf02 または /webapp/webapp9mb02)
#   SHARED_CONF_SYMLINK  off(既定) | on   ビルド時と同じ値にすること
#   SHARED_CONF_OVERLAY  off(既定) | on   Deployment Overlays を使うか
#   SHARED_CONF_OVERLAY_AUTO  on(既定) | off  起動時に自動適用するか
#                              (off なら deployment-overlay.sh を手動実行する運用)
#   SHARED_CONF_DIR      既定 /mnt/logs/tmp
#   SHARED_CONF_SEED     on(既定) | off   実体が無いときに初期値から生成するか
#   SHARED_CONF_STRICT   on(既定) | off   検証に失敗したとき起動を中止するか
#   SHARED_CONF_MODE     既定 0664        生成する実体ファイルの permission
#   SHARED_CONF_WAIT     既定 30          EFS マウント待ちの最大秒数
#   SHARED_CONF_MOUNT    既定は自動判定    EFS マウントポイント (待ち合わせ対象)
#   (overlay 側のパラメータは deployment-overlay.sh のヘッダを参照)
# ============================================================================
set -eu

SC_TAG="shared-conf/init"
. "$(dirname "$0")/linkmap-lib.sh"

: "${SHARED_CONF_SYMLINK:=off}"
: "${SHARED_CONF_OVERLAY:=off}"
: "${SHARED_CONF_OVERLAY_AUTO:=on}"
: "${SHARED_CONF_OVERLAY_SOURCE:=auto}"
: "${SHARED_CONF_SEED:=on}"
: "${SHARED_CONF_STRICT:=on}"
: "${SHARED_CONF_MODE:=0664}"
: "${SHARED_CONF_WAIT:=30}"

SHARED_CONF_SYMLINK=$(sc_flag      SHARED_CONF_SYMLINK      "${SHARED_CONF_SYMLINK}")      || exit 1
SHARED_CONF_OVERLAY=$(sc_flag      SHARED_CONF_OVERLAY      "${SHARED_CONF_OVERLAY}")      || exit 1
SHARED_CONF_OVERLAY_AUTO=$(sc_flag SHARED_CONF_OVERLAY_AUTO "${SHARED_CONF_OVERLAY_AUTO}") || exit 1
SHARED_CONF_SEED=$(sc_flag         SHARED_CONF_SEED         "${SHARED_CONF_SEED}")         || exit 1
SHARED_CONF_STRICT=$(sc_flag       SHARED_CONF_STRICT       "${SHARED_CONF_STRICT}")       || exit 1
SHARED_CONF_OVERLAY_SOURCE=$(sc_enum SHARED_CONF_OVERLAY_SOURCE "${SHARED_CONF_OVERLAY_SOURCE}" auto target link) || exit 1

if [ -z "${APP_ROOT:-}" ]; then
    sc_err "APP_ROOT が設定されていません。"
    sc_err "  Dockerfile の ENV かタスク定義の environment で"
    sc_err "  /webapp/webapp9mf02 (front) または /webapp/webapp9mb02 (back) を設定してください。"
    exit 1
fi

sc_log "APP_ROOT=${APP_ROOT} symlink=${SHARED_CONF_SYMLINK} overlay=${SHARED_CONF_OVERLAY} seed=${SHARED_CONF_SEED} strict=${SHARED_CONF_STRICT}"
sc_log "uid=$(id -u) gid=$(id -g)"

# ===========================================================================
# EFS 上の実体が必要かどうかの判定
#   symlink=on              : 必須 (リンク先そのもの)
#   overlay=on かつ source が auto/target : 必須 (オーバレイ元として読む)
#   それ以外                : 不要 = EFS には一切触れない
# ===========================================================================
_need_efs=off
if [ "${SHARED_CONF_SYMLINK}" = "on" ]; then
    _need_efs=on
elif [ "${SHARED_CONF_OVERLAY}" = "on" ]; then
    case "${SHARED_CONF_OVERLAY_SOURCE}" in
        auto|target) _need_efs=on ;;
    esac
fi

_prep_rc=0

# ===========================================================================
# 1) EFS マウント待ち + 共有ディレクトリの確保
#    Fargate はコンテナ起動前にマウントを完了させるが、NFS の初回応答が
#    遅れるケースに備えて短くリトライする。
# ===========================================================================
if [ "${_need_efs}" = "on" ]; then
    # EFS マウントポイントの判定。既定は SHARED_CONF_DIR の先頭2階層。
    #   /mnt/logs/tmp                       -> /mnt/logs
    #   /mnt/logs/front/logs/intra-web/tmp  -> /mnt/logs
    # 異なる構成の場合は SHARED_CONF_MOUNT で明示指定する。
    if [ -n "${SHARED_CONF_MOUNT:-}" ]; then
        _efs_mnt="${SHARED_CONF_MOUNT}"
    else
        _efs_mnt=$(printf '%s' "${SHARED_CONF_DIR}" | sed -e 's|^\(/[^/]*/[^/]*\).*|\1|')
    fi

    _waited=0
    while [ ! -d "${_efs_mnt}" ]; do
        if [ "${_waited}" -ge "${SHARED_CONF_WAIT}" ]; then
            sc_err "${_efs_mnt} が ${SHARED_CONF_WAIT} 秒経ってもマウントされません。"
            sc_err "タスク定義の mountPoints / efsVolumeConfiguration を確認してください。"
            if [ "${SHARED_CONF_STRICT}" = "on" ]; then
                exit 1
            fi
            break
        fi
        sc_log "${_efs_mnt} のマウント待ち... (${_waited}s)"
        sleep 2
        _waited=$((_waited + 2))
    done

    if [ ! -d "${SHARED_CONF_DIR}" ]; then
        if mkdir -p "${SHARED_CONF_DIR}" 2>/dev/null; then
            chmod 2775 "${SHARED_CONF_DIR}" 2>/dev/null || true
            sc_log "共有ディレクトリを作成しました: ${SHARED_CONF_DIR}"
        else
            sc_err "${SHARED_CONF_DIR} を作成できません (uid=$(id -u) gid=$(id -g))。"
            sc_err "EC2 側で ec2/init-shared-conf.sh を先に実行してください。"
        fi
    fi
else
    sc_log "EFS への準備処理はスキップします (symlink=off / オーバレイ元もイメージ内ファイル)"
fi

# ===========================================================================
# 2) 実体ファイルのシード (存在しない場合のみ / アトミック)
#    8 コンテナ (4 サービス x front/back) が同時起動しても壊れないよう、
#    「一時ファイルを作ってから link(2) で公開する」方式を使う。
#    link(2) は NFSv4 上でもアトミックで、既に存在すれば EEXIST で失敗する。
# ===========================================================================
_seed_one() {
    _link="$1"; _target="$2"; _default="$3"

    if [ -e "$_target" ]; then
        # 既存を尊重 (= タスク再起動で内容が維持される)。
        # ただしイメージ同梱の初期値と差異があることは INFO として可視化しておく。
        if [ -r "$_default" ] && ! cmp -s "$_default" "$_target"; then
            sc_log "既存を維持 (イメージ既定値とは差分あり): ${_target}"
        else
            sc_log "既存を維持: ${_target}"
        fi
        return 0
    fi

    if [ "${SHARED_CONF_SEED}" != "on" ]; then
        sc_warn "実体が存在せず SHARED_CONF_SEED=off のためシードしません: ${_target}"
        return 0
    fi

    # シード元は defaults を優先。symlink=off ビルド (= defaults を作らない) で
    # overlay だけ使う構成のために、イメージ内の実ファイルにもフォールバックする。
    _seed_src="$_default"
    if [ ! -r "$_seed_src" ]; then
        if [ -f "$_link" ] && [ ! -L "$_link" ]; then
            _seed_src="$_link"
            sc_log "初期値が無いためイメージ内の実ファイルをシード元にします: ${_link}"
        else
            sc_err "初期値が読めません: ${_default}"
            sc_err "  シード元を持たないビルド (実ファイルなしで symlink 化) の場合は、"
            sc_err "  ${_target} を EFS 上に用意してください (ec2/init-shared-conf.sh 等)。"
            return 1
        fi
    fi

    _dir=$(dirname "$_target")
    mkdir -p "$_dir" 2>/dev/null || true

    _tmp="${_dir}/.seed.$$.$(date +%s).tmp"
    if ! cp "$_seed_src" "$_tmp" 2>/dev/null; then
        sc_err "${_dir} に書き込めません。EFS の所有者/権限 (6301:6302) を確認してください。"
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    chmod "${SHARED_CONF_MODE}" "$_tmp" 2>/dev/null || true

    if ln "$_tmp" "$_target" 2>/dev/null; then
        sc_log "実体を初期生成しました: ${_target} (from ${_seed_src})"
    else
        sc_log "実体は他コンテナが先に生成済み: ${_target}"
    fi
    rm -f "$_tmp" 2>/dev/null || true
    return 0
}

if [ "${_need_efs}" = "on" ]; then
    sc_each_entry _seed_one || _prep_rc=1
fi

# ===========================================================================
# 3) 検証
#    symlink=on : リンクが解決できるか
#    symlink=off: イメージ内の実ファイルとして読めるか
# ===========================================================================
_verify_link_one() {
    _link="$1"; _target="$2"

    if [ ! -L "$_link" ]; then
        sc_err "シンボリックリンクではありません: ${_link}"
        sc_err "  イメージのビルド時 (build-shared-links.sh) が実行されていない可能性があります。"
        return 1
    fi
    _actual=$(readlink "$_link")
    if [ "$_actual" != "$_target" ]; then
        sc_err "リンク先が linkmap と不一致: ${_link} -> ${_actual} (期待: ${_target})"
        sc_err "  リンク先はイメージに焼き込まれています。変更にはイメージ再ビルドが必要です。"
        return 1
    fi
    if [ ! -e "$_link" ]; then
        sc_err "リンクが解決できません (dangling): ${_link} -> ${_target}"
        return 1
    fi
    if [ ! -r "$_link" ]; then
        sc_err "読み取り権限がありません: ${_link} (uid=$(id -u) gid=$(id -g))"
        return 1
    fi
    sc_log "検証OK: ${_link} -> ${_target} ($(wc -c < "$_link" | tr -d ' ') bytes)"
    return 0
}

_check_plain_one() {
    _link="$1"

    if [ -L "$_link" ]; then
        sc_err "SHARED_CONF_SYMLINK=off ですが symlink になっています: ${_link} -> $(readlink "$_link")"
        sc_err "  イメージが SHARED_CONF_SYMLINK=on でビルドされている可能性があります。"
        sc_err "  ビルド時と実行時で値を揃えてください (Dockerfile の ARG/ENV を確認)。"
        return 1
    fi
    if [ ! -f "$_link" ]; then
        sc_err "ファイルが存在しません: ${_link}"
        return 1
    fi
    if [ ! -r "$_link" ]; then
        sc_err "読み取り権限がありません: ${_link} (uid=$(id -u) gid=$(id -g))"
        return 1
    fi
    sc_log "検証OK: ${_link} (イメージ内の実ファイル / $(wc -c < "$_link" | tr -d ' ') bytes)"
    return 0
}

if [ "${SHARED_CONF_SYMLINK}" = "on" ]; then
    sc_each_entry _verify_link_one || _prep_rc=1
else
    sc_each_entry _check_plain_one || _prep_rc=1
fi

if [ "${_prep_rc}" -ne 0 ]; then
    if [ "${SHARED_CONF_STRICT}" = "on" ]; then
        sc_err "設定ファイルの準備に失敗したため起動を中止します (SHARED_CONF_STRICT=on)"
        exit 1
    fi
    sc_warn "設定ファイルの準備に失敗しましたが SHARED_CONF_STRICT=off のため続行します"
fi

# ===========================================================================
# 4) Deployment Overlays (追加機能 / 既定 off)
#    jboss-cli は「サーバが起動してから」でないと接続できないため、
#    exec の前にバックグラウンドで起動し、スクリプト側で running を待つ。
#    exec 後は JBoss が PID 1 になるので、このプロセスはその子として残る。
# ===========================================================================
if [ "${SHARED_CONF_OVERLAY}" = "on" ]; then
    if [ "${SHARED_CONF_OVERLAY_AUTO}" = "on" ]; then
        sc_log "Deployment Overlay をバックグラウンドで適用します (サーバ起動後)"
        "$(dirname "$0")/deployment-overlay.sh" startup &
    else
        sc_log "SHARED_CONF_OVERLAY_AUTO=off のため自動適用しません。"
        sc_log "  手動適用: $(dirname "$0")/deployment-overlay.sh apply"
    fi
fi

sc_log "準備完了。アプリケーションを起動します: $*"

# ---------------------------------------------------------------------------
# 5) 本来のプロセスへ (PID 1 を引き継ぐので SIGTERM が JBoss に届く)
# ---------------------------------------------------------------------------
exec "$@"
