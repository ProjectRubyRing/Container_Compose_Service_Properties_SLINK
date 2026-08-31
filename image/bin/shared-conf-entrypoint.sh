#!/bin/sh
# ============================================================================
# shared-conf-entrypoint.sh  --  【実行時】entrypoint ラッパ。appuser(6301) で実行。
# ============================================================================
# 役割は「EFS 上の実体ファイルを用意すること」だけ。
# /webapp 配下 (readonlyRootFilesystem=true) には一切書き込まない。
#
#   1) ${SHARED_CONF_DIR} (= /mnt/logs/tmp) が使えることを確認 (EFS マウント待ち)
#   2) 実体が「存在しない場合のみ」イメージ内の初期値から生成 (アトミック)
#      → 既に存在するなら絶対に上書きしない = ECS タスク再起動でも内容が維持される
#   3) 各シンボリックリンクが実際に解決できることを検証 (fail fast)
#   4) exec で本来のプロセス (JBoss EAP の起動コマンド) に引き継ぐ
#
# SHARED_CONF_SYMLINK=off (= symlink なしでビルドしたイメージ) の場合は
# 1)〜3) をスキップし、対象がイメージ内の実ファイルであることだけ確認して exec する。
# EFS へのアクセスも一切行わないので、共有機構なしの構成でも同じ entrypoint で動く。
#
# Dockerfile:
#   ENTRYPOINT ["/opt/app/shared-conf/bin/shared-conf-entrypoint.sh"]
#   CMD ["/opt/eap/bin/standalone.sh", "-b", "0.0.0.0"]
#
# 環境変数:
#   APP_ROOT            必須 (/webapp/webapp9mf02 または /webapp/webapp9mb02)
#   SHARED_CONF_SYMLINK on(既定) | off   ビルド時と同じ値。off なら共有機構を無効化
#   SHARED_CONF_DIR     既定 /mnt/logs/tmp
#   SHARED_CONF_SEED    on(既定) | off   実体が無いときに初期値から生成するか
#   SHARED_CONF_STRICT  on(既定) | off   リンクが解決できないとき起動を中止するか
#   SHARED_CONF_MODE    既定 0664        生成する実体ファイルの permission
#   SHARED_CONF_WAIT    既定 30          EFS マウント待ちの最大秒数
#   SHARED_CONF_MOUNT   既定は自動判定    EFS マウントポイント (待ち合わせ対象)
# ============================================================================
set -eu

SC_TAG="shared-conf/init"
. "$(dirname "$0")/linkmap-lib.sh"

: "${SHARED_CONF_SYMLINK:=on}"
: "${SHARED_CONF_SEED:=on}"
: "${SHARED_CONF_STRICT:=on}"
: "${SHARED_CONF_MODE:=0664}"
: "${SHARED_CONF_WAIT:=30}"

SHARED_CONF_SYMLINK=$(sc_flag SHARED_CONF_SYMLINK "${SHARED_CONF_SYMLINK}") || exit 1
SHARED_CONF_SEED=$(sc_flag    SHARED_CONF_SEED    "${SHARED_CONF_SEED}")    || exit 1
SHARED_CONF_STRICT=$(sc_flag  SHARED_CONF_STRICT  "${SHARED_CONF_STRICT}")  || exit 1

if [ -z "${APP_ROOT:-}" ]; then
    sc_err "APP_ROOT が設定されていません。"
    sc_err "  Dockerfile の ENV かタスク定義の environment で"
    sc_err "  /webapp/webapp9mf02 (front) または /webapp/webapp9mb02 (back) を設定してください。"
    exit 1
fi

# ===========================================================================
# SHARED_CONF_SYMLINK=off : 共有機構なしのイメージ
#   EFS には触れない。対象が実ファイルとして読めることだけ確認して起動する。
# ===========================================================================
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

if [ "${SHARED_CONF_SYMLINK}" = "off" ]; then
    sc_log "APP_ROOT=${APP_ROOT} symlink=off (共有機構は無効。EFS 待ち・シード・リンク検証をスキップ)"
    sc_log "uid=$(id -u) gid=$(id -g)"

    _plain_rc=0
    sc_each_entry _check_plain_one || _plain_rc=1

    if [ "${_plain_rc}" -ne 0 ]; then
        if [ "${SHARED_CONF_STRICT}" = "on" ]; then
            sc_err "設定ファイルの確認に失敗したため起動を中止します (SHARED_CONF_STRICT=on)"
            exit 1
        fi
        sc_warn "設定ファイルの確認に失敗しましたが SHARED_CONF_STRICT=off のため続行します"
    fi

    sc_log "準備完了。アプリケーションを起動します: $*"
    exec "$@"
fi

# ===========================================================================
# SHARED_CONF_SYMLINK=on : EFS 上の実体を用意してから起動する
# ===========================================================================
sc_log "APP_ROOT=${APP_ROOT} SHARED_CONF_DIR=${SHARED_CONF_DIR} seed=${SHARED_CONF_SEED} strict=${SHARED_CONF_STRICT}"
sc_log "uid=$(id -u) gid=$(id -g)"

# ---------------------------------------------------------------------------
# 1) EFS マウント待ち + 共有ディレクトリの確保
#    Fargate はコンテナ起動前にマウントを完了させるが、NFS の初回応答が
#    遅れるケースに備えて短くリトライする。
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 2) 実体ファイルのシード (存在しない場合のみ / アトミック)
#    8 コンテナ (4 サービス x front/back) が同時起動しても壊れないよう、
#    「一時ファイルを作ってから link(2) で公開する」方式を使う。
#    link(2) は NFSv4 上でもアトミックで、既に存在すれば EEXIST で失敗する。
# ---------------------------------------------------------------------------
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

    if [ ! -r "$_default" ]; then
        sc_err "初期値が読めません: ${_default}"
        return 1
    fi

    _dir=$(dirname "$_target")
    mkdir -p "$_dir" 2>/dev/null || true

    _tmp="${_dir}/.seed.$$.$(date +%s).tmp"
    if ! cp "$_default" "$_tmp" 2>/dev/null; then
        sc_err "${_dir} に書き込めません。EFS の所有者/権限 (6301:6302) を確認してください。"
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    chmod "${SHARED_CONF_MODE}" "$_tmp" 2>/dev/null || true

    if ln "$_tmp" "$_target" 2>/dev/null; then
        sc_log "実体を初期生成しました: ${_target} (from ${_default})"
    else
        sc_log "実体は他コンテナが先に生成済み: ${_target}"
    fi
    rm -f "$_tmp" 2>/dev/null || true
    return 0
}

_seed_rc=0
sc_each_entry _seed_one || _seed_rc=1

# ---------------------------------------------------------------------------
# 3) リンク解決の検証
# ---------------------------------------------------------------------------
_verify_one() {
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

_verify_rc=0
sc_each_entry _verify_one || _verify_rc=1

if [ "${_seed_rc}" -ne 0 ] || [ "${_verify_rc}" -ne 0 ]; then
    if [ "${SHARED_CONF_STRICT}" = "on" ]; then
        sc_err "共有設定ファイルの準備に失敗したため起動を中止します (SHARED_CONF_STRICT=on)"
        exit 1
    fi
    sc_warn "共有設定ファイルの準備に失敗しましたが SHARED_CONF_STRICT=off のため続行します"
fi

sc_log "準備完了。アプリケーションを起動します: $*"

# ---------------------------------------------------------------------------
# 4) 本来のプロセスへ (PID 1 を引き継ぐので SIGTERM が JBoss に届く)
# ---------------------------------------------------------------------------
exec "$@"
