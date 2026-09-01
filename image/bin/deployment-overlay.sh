#!/bin/sh
# ============================================================================
# deployment-overlay.sh  --  【実行時】JBoss EAP の Deployment Overlay を適用する
# ============================================================================
# symlink 機構 (build-shared-links.sh / shared-conf-entrypoint.sh) とは独立した
# 「追加機能」。配備済みの WAR アーカイブを一切書き換えずに、
# linkmap.conf の各エントリのファイル内容を jboss-cli.sh 経由で
# デプロイメントに被せる (= Deployment Overlays)。
#
#   EFS 上の実体  /mnt/logs/tmp/date_config.properties
#        |  (このファイルの中身を)
#        v  deployment-overlay add --content=<アーカイブ内パス>=<実体パス>
#   配備済み      xxx.war!/WEB-INF/classes/jp/co/sample/base/date_config.properties
#                 ^^^ アーカイブは書き換わらない。管理レイヤで上書きされるだけ
#
# アーカイブ内パスは `deployment browse-content` で実際の配備内容を列挙して
# 決定する (同名ファイルが複数の WAR に入っていても全部拾える)。
#
# ---- サブコマンド ----------------------------------------------------------
#   apply    (既定) overlay を適用する。手動再適用もこれ (ECS Exec から実行可)
#   startup  entrypoint がバックグラウンドで呼ぶ用。apply と同じだが
#            失敗時に SHARED_CONF_OVERLAY_STRICT=on なら PID 1 に SIGTERM を送る
#   status   現在の overlay 登録状況を表示する
#   browse   deployment browse-content の生出力を表示する (調査用)
#   remove   このスクリプトが作った overlay を削除する (切り戻し)
#
# ---- 重要な性質 ------------------------------------------------------------
#   * overlay の内容は add/upload した「その時点のコピー」がコンテンツリポジトリに
#     取り込まれる。EFS 側を編集しても再適用するまで反映されない。
#     -> 編集後は `deployment-overlay.sh apply` を再実行すること。
#   * jboss-cli の管理操作なので、standalone の管理ポートに接続できること、
#     および JBoss がコンテンツリポジトリと standalone.xml に
#     書き込めることが前提 (docs/deployment-overlay.md §4)。
#
# 使い方 (コンテナ内 / ECS Exec):
#   /opt/app/shared-conf/bin/deployment-overlay.sh apply
# ============================================================================
set -eu

SC_TAG="shared-conf/overlay"
. "$(dirname "$0")/linkmap-lib.sh"

: "${SHARED_CONF_OVERLAY:=off}"
: "${SHARED_CONF_OVERLAY_NAME:=shared-conf}"
: "${SHARED_CONF_OVERLAY_SOURCE:=auto}"          # auto | target | link
: "${SHARED_CONF_OVERLAY_MATCH:=name}"           # name | path
: "${SHARED_CONF_OVERLAY_BROWSE:=on}"            # browse-content で配備内容を実測するか
: "${SHARED_CONF_OVERLAY_DEPLOYMENTS:=auto}"     # auto | "a.war,b.war"
: "${SHARED_CONF_OVERLAY_REDEPLOY:=on}"          # --redeploy-affected を付けるか
: "${SHARED_CONF_OVERLAY_STRICT:=off}"           # startup 時、失敗をコンテナ停止にするか
: "${SHARED_CONF_OVERLAY_DRYRUN:=off}"           # 実行せず CLI コマンドを表示するだけ
: "${SHARED_CONF_OVERLAY_WAIT:=180}"             # 起動完了を待つ最大秒数
: "${SHARED_CONF_OVERLAY_INTERVAL:=3}"           # 起動完了ポーリング間隔(秒)

: "${JBOSS_HOME:=/opt/eap}"
: "${SHARED_CONF_CLI:=${JBOSS_HOME}/bin/jboss-cli.sh}"
: "${SHARED_CONF_CLI_CONTROLLER:=remote+http://127.0.0.1:9990}"

SC_SUBCMD="${1:-apply}"

SHARED_CONF_OVERLAY=$(sc_flag          SHARED_CONF_OVERLAY          "${SHARED_CONF_OVERLAY}")          || exit 1
SHARED_CONF_OVERLAY_BROWSE=$(sc_flag   SHARED_CONF_OVERLAY_BROWSE   "${SHARED_CONF_OVERLAY_BROWSE}")   || exit 1
SHARED_CONF_OVERLAY_REDEPLOY=$(sc_flag SHARED_CONF_OVERLAY_REDEPLOY "${SHARED_CONF_OVERLAY_REDEPLOY}") || exit 1
SHARED_CONF_OVERLAY_STRICT=$(sc_flag   SHARED_CONF_OVERLAY_STRICT   "${SHARED_CONF_OVERLAY_STRICT}")   || exit 1
SHARED_CONF_OVERLAY_DRYRUN=$(sc_flag   SHARED_CONF_OVERLAY_DRYRUN   "${SHARED_CONF_OVERLAY_DRYRUN}")   || exit 1
SHARED_CONF_OVERLAY_SOURCE=$(sc_enum   SHARED_CONF_OVERLAY_SOURCE   "${SHARED_CONF_OVERLAY_SOURCE}" auto target link) || exit 1
SHARED_CONF_OVERLAY_MATCH=$(sc_enum    SHARED_CONF_OVERLAY_MATCH    "${SHARED_CONF_OVERLAY_MATCH}"  name path)        || exit 1

if [ -z "${APP_ROOT:-}" ]; then
    sc_err "APP_ROOT が設定されていません。"
    exit 1
fi

SC_WORK=$(mktemp -d "${TMPDIR:-/tmp}/shared-conf-overlay.XXXXXX")
trap 'rm -rf "${SC_WORK}"' EXIT INT TERM

SC_TABCHR=$(printf '\t')

# ===========================================================================
# jboss-cli 実行まわり
# ===========================================================================

# sc_cli <commands 文字列>
#   stdout に CLI の出力 (stderr 混み)、戻り値は CLI の終了コード。
#   認証情報は環境変数がある場合のみ渡す (ローカル認証なら不要)。
sc_cli() {
    if [ ! -x "${SHARED_CONF_CLI}" ]; then
        sc_err "jboss-cli が見つからない/実行できません: ${SHARED_CONF_CLI}"
        sc_err "  JBOSS_HOME か SHARED_CONF_CLI を実際の配置に合わせてください。"
        return 127
    fi
    if [ -n "${SHARED_CONF_CLI_USER:-}" ]; then
        "${SHARED_CONF_CLI}" --connect \
            --controller="${SHARED_CONF_CLI_CONTROLLER}" \
            --user="${SHARED_CONF_CLI_USER}" \
            --password="${SHARED_CONF_CLI_PASSWORD:-}" \
            --command="$1" 2>&1
    else
        "${SHARED_CONF_CLI}" --connect \
            --controller="${SHARED_CONF_CLI_CONTROLLER}" \
            --command="$1" 2>&1
    fi
}

# sc_cli_run <説明> <commands 文字列>
#   DRYRUN=on なら実行せず表示のみ。失敗時は出力をエラーとして出す。
sc_cli_run() {
    _ov_desc="$1"; _ov_cmds="$2"

    if [ "${SHARED_CONF_OVERLAY_DRYRUN}" = "on" ]; then
        sc_log "[dry-run] ${_ov_desc}"
        sc_log "[dry-run]   jboss-cli> ${_ov_cmds}"
        return 0
    fi

    _ov_rc=0
    _ov_out=$(sc_cli "${_ov_cmds}") || _ov_rc=$?
    if [ "${_ov_rc}" -ne 0 ]; then
        sc_err "${_ov_desc} に失敗しました (rc=${_ov_rc})"
        sc_err "  cmd: ${_ov_cmds}"
        printf '%s\n' "${_ov_out}" | sed -e 's/^/  | /' >&2
        return 1
    fi
    sc_log "${_ov_desc}"
    return 0
}

# サーバが running になるまで待つ (standalone 前提)
sc_wait_ready() {
    _ov_waited=0
    while : ; do
        _ov_rc=0
        _ov_out=$(sc_cli ':read-attribute(name=server-state)') || _ov_rc=$?
        if [ "${_ov_rc}" -eq 0 ] && printf '%s' "${_ov_out}" | grep -q '"running"'; then
            sc_log "サーバ起動を確認しました (${_ov_waited}s)"
            return 0
        fi
        if [ "${_ov_waited}" -ge "${SHARED_CONF_OVERLAY_WAIT}" ]; then
            sc_err "${SHARED_CONF_OVERLAY_WAIT} 秒待ってもサーバが running になりません。"
            sc_err "  controller=${SHARED_CONF_CLI_CONTROLLER}"
            sc_err "  管理インタフェースが待ち受けているか (-bmanagement) を確認してください。"
            printf '%s\n' "${_ov_out}" | tail -n 5 | sed -e 's/^/  | /' >&2
            return 1
        fi
        sleep "${SHARED_CONF_OVERLAY_INTERVAL}"
        _ov_waited=$((_ov_waited + SHARED_CONF_OVERLAY_INTERVAL))
    done
}

# 書き込み可能性の事前チェック (失敗しても続行。原因を先に見せるための診断)
sc_precheck() {
    for _ov_d in "${JBOSS_HOME}/standalone/configuration" "${JBOSS_HOME}/standalone/data"; do
        if [ -d "${_ov_d}" ] && [ ! -w "${_ov_d}" ]; then
            sc_warn "書き込めません: ${_ov_d}"
            sc_warn "  deployment-overlay は standalone.xml とコンテンツリポジトリを更新します。"
            sc_warn "  readonlyRootFilesystem=true の場合、この 2 つは書き込み可能なボリュームに"
            sc_warn "  乗せておく必要があります (docs/deployment-overlay.md §4)。"
        fi
    done
}

# ===========================================================================
# デプロイメントの列挙
# ===========================================================================
sc_list_deployments() {
    if [ "${SHARED_CONF_OVERLAY_DEPLOYMENTS}" != "auto" ]; then
        printf '%s' "${SHARED_CONF_OVERLAY_DEPLOYMENTS}" \
            | tr ',;' '  ' | tr -s ' \t' '\n\n' | sed -e 's/\r$//' -e '/^$/d'
        return 0
    fi

    _ov_rc=0
    _ov_out=$(sc_cli 'deployment list') || _ov_rc=$?
    if [ "${_ov_rc}" -ne 0 ]; then
        sc_err "deployment list に失敗しました (rc=${_ov_rc})"
        printf '%s\n' "${_ov_out}" | sed -e 's/^/  | /' >&2
        return 1
    fi
    # `deployment list` は名前を空白/改行区切りで並べる。
    # 名前として妥当なトークンだけを拾い、誤検出は browse-content 側で弾く。
    printf '%s\n' "${_ov_out}" \
        | tr -s ' \t' '\n\n' | sed -e 's/\r$//' -e '/^$/d' \
        | grep -E '^[A-Za-z0-9][A-Za-z0-9._@#+-]*$' || true
}

# ===========================================================================
# アーカイブ内容の列挙 (deployment browse-content)
#   ディレクトリ (末尾 /) は落とし、ファイルのパスだけを1行1件で返す。
# ===========================================================================
sc_browse_content() {
    _ov_rc=0
    _ov_out=$(sc_cli "deployment browse-content --name=$1") || _ov_rc=$?
    if [ "${_ov_rc}" -ne 0 ]; then
        return 1
    fi
    printf '%s\n' "${_ov_out}" \
        | sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '/$' | sed -e '/^$/d'
}

# sc_match_paths <listing-file> <needle>
#   listing から「needle そのもの」または「*/needle」で終わる行を拾う。
#   glob の case を使うので、パスに含まれる正規表現メタ文字を気にしなくてよい。
sc_match_paths() {
    while IFS= read -r _ov_p; do
        case "${_ov_p}" in
            "$2"|*/"$2") printf '%s\n' "${_ov_p}" ;;
        esac
    done < "$1"
}

# ===========================================================================
# linkmap エントリの収集と、オーバレイ元ファイルの決定
# ===========================================================================
_collect_entry() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "${SC_WORK}/entries.tsv"
    return 0
}

# sc_resolve_source <link> <target>
sc_resolve_source() {
    case "${SHARED_CONF_OVERLAY_SOURCE}" in
        target) printf '%s' "$2"; return 0 ;;
        link)   printf '%s' "$1"; return 0 ;;
    esac
    # auto: EFS 上の実体を優先し、無ければイメージ内のファイルにフォールバック
    if [ -f "$2" ] && [ -r "$2" ]; then printf '%s' "$2"; return 0; fi
    if [ -f "$1" ] && [ -r "$1" ]; then printf '%s' "$1"; return 0; fi
    return 1
}

# entries.tsv -> sources.tsv (needle / src / 明示パス / フォールバックパス)
sc_build_sources() {
    : > "${SC_WORK}/entries.tsv"
    if ! sc_each_entry _collect_entry; then
        sc_err "linkmap の読み込みに失敗しました"
        return 1
    fi

    : > "${SC_WORK}/sources.tsv"
    _ov_srcrc=0
    while IFS="${SC_TABCHR}" read -r _ov_link _ov_target _ov_default _ov_ovlpath; do
        [ -z "${_ov_link}" ] && continue

        _ov_src=""
        if ! _ov_src=$(sc_resolve_source "${_ov_link}" "${_ov_target}"); then
            sc_err "オーバレイ元のファイルが読めません (source=${SHARED_CONF_OVERLAY_SOURCE})"
            sc_err "  TARGET: ${_ov_target}"
            sc_err "  LINK  : ${_ov_link}"
            _ov_srcrc=1
            continue
        fi
        if [ ! -r "${_ov_src}" ]; then
            sc_err "オーバレイ元のファイルが読めません: ${_ov_src}"
            _ov_srcrc=1
            continue
        fi

        # 突き合わせに使う needle と、browse が使えない場合の既定パス
        if [ "${SHARED_CONF_OVERLAY_MATCH}" = "path" ]; then
            _ov_needle=$(sc_rel_path "${_ov_link}")
        else
            _ov_needle=$(basename "${_ov_link}")
        fi
        if [ "${_ov_ovlpath}" = "-" ]; then
            _ov_fallback=$(sc_rel_path "${_ov_link}")
        else
            _ov_fallback="${_ov_ovlpath}"
        fi

        printf '%s\t%s\t%s\t%s\n' \
            "${_ov_needle}" "${_ov_src}" "${_ov_ovlpath}" "${_ov_fallback}" \
            >> "${SC_WORK}/sources.tsv"
        sc_log "オーバレイ元: ${_ov_src}  (照合キー: ${_ov_needle})"
    done < "${SC_WORK}/entries.tsv"

    if [ ! -s "${SC_WORK}/sources.tsv" ]; then
        sc_err "オーバレイ対象のエントリがありません (linkmap: ${SHARED_CONF_LINKMAP})"
        return 1
    fi
    return "${_ov_srcrc}"
}

# ===========================================================================
# overlay の適用
# ===========================================================================
sc_overlay_name_for() {
    printf '%s-%s' "${SHARED_CONF_OVERLAY_NAME}" "$(sc_sanitize_name "$1")"
}

sc_overlay_exists() {
    [ "${SHARED_CONF_OVERLAY_DRYRUN}" = "on" ] && return 1
    sc_cli "deployment-overlay list-content --name=$1" >/dev/null 2>&1
}

# sc_apply_one <deployment> <content 引数 (a=b,c=d)>
sc_apply_one() {
    _ov_dep="$1"; _ov_content="$2"
    _ov_name=$(sc_overlay_name_for "${_ov_dep}")
    _ov_rd=""
    [ "${SHARED_CONF_OVERLAY_REDEPLOY}" = "on" ] && _ov_rd=" --redeploy-affected"

    if sc_overlay_exists "${_ov_name}"; then
        # 既存 overlay: 内容を差し替え、リンクを保証してから再デプロイ
        sc_cli_run "overlay 更新: ${_ov_name}" \
            "deployment-overlay upload --name=${_ov_name} --content=${_ov_content}" || return 1
        # 既にリンク済みなら CLI がエラーを返すが、それは正常系なので握りつぶす
        if ! sc_cli "deployment-overlay link --name=${_ov_name} --deployments=${_ov_dep}" >/dev/null 2>&1; then
            sc_log "overlay は既に ${_ov_dep} にリンク済みです: ${_ov_name}"
        fi
        if [ "${SHARED_CONF_OVERLAY_REDEPLOY}" = "on" ]; then
            sc_cli_run "再デプロイ: ${_ov_dep}" \
                "deployment-overlay redeploy-affected --name=${_ov_name}" || return 1
        fi
    else
        sc_cli_run "overlay 作成: ${_ov_name} -> ${_ov_dep}" \
            "deployment-overlay add --name=${_ov_name} --content=${_ov_content} --deployments=${_ov_dep}${_ov_rd}" || return 1
    fi
    return 0
}

# sc_verify_one <deployment> <paths-file>
#   list-content / list-links で「本当に登録されたか」を確認する。
sc_verify_one() {
    [ "${SHARED_CONF_OVERLAY_DRYRUN}" = "on" ] && return 0
    _ov_dep="$1"; _ov_pf="$2"
    _ov_name=$(sc_overlay_name_for "${_ov_dep}")

    _ov_rc=0
    _ov_lc=$(sc_cli "deployment-overlay list-content --name=${_ov_name}") || _ov_rc=$?
    if [ "${_ov_rc}" -ne 0 ]; then
        sc_err "検証失敗: overlay ${_ov_name} の内容を取得できません"
        return 1
    fi
    _ov_ll=$(sc_cli "deployment-overlay list-links --name=${_ov_name}") || _ov_rc=$?
    if [ "${_ov_rc}" -ne 0 ]; then
        sc_err "検証失敗: overlay ${_ov_name} のリンクを取得できません"
        return 1
    fi

    if ! printf '%s\n' "${_ov_ll}" | grep -qF -- "${_ov_dep}"; then
        sc_err "検証失敗: overlay ${_ov_name} が ${_ov_dep} にリンクされていません"
        return 1
    fi
    while IFS= read -r _ov_p; do
        [ -z "${_ov_p}" ] && continue
        if ! printf '%s\n' "${_ov_lc}" | grep -qF -- "${_ov_p}"; then
            sc_err "検証失敗: overlay ${_ov_name} に ${_ov_p} が登録されていません"
            return 1
        fi
    done < "${_ov_pf}"

    sc_log "検証OK: ${_ov_dep} <- ${_ov_name} ($(wc -l < "${_ov_pf}" | tr -d ' ') パス)"
    return 0
}

# ===========================================================================
# サブコマンド: apply
# ===========================================================================
sc_cmd_apply() {
    sc_log "APP_ROOT=${APP_ROOT} overlay=on source=${SHARED_CONF_OVERLAY_SOURCE} match=${SHARED_CONF_OVERLAY_MATCH} browse=${SHARED_CONF_OVERLAY_BROWSE} redeploy=${SHARED_CONF_OVERLAY_REDEPLOY}"
    sc_log "controller=${SHARED_CONF_CLI_CONTROLLER} cli=${SHARED_CONF_CLI}"
    [ "${SHARED_CONF_OVERLAY_DRYRUN}" = "on" ] && sc_log "DRY-RUN モードです (実際の変更は行いません)"

    sc_precheck
    sc_wait_ready || return 1
    sc_build_sources || return 1

    _ov_deps=$(sc_list_deployments) || return 1
    if [ -z "${_ov_deps}" ]; then
        sc_err "デプロイメントが1つも見つかりません。"
        sc_err "  SHARED_CONF_OVERLAY_DEPLOYMENTS で明示指定することもできます。"
        return 1
    fi

    _ov_total=0
    _ov_rc_all=0
    _ov_n=0

    for _ov_dep in ${_ov_deps}; do
        _ov_n=$((_ov_n + 1))
        _ov_list="${SC_WORK}/browse.${_ov_n}"
        _ov_paths="${SC_WORK}/paths.${_ov_n}"
        : > "${_ov_paths}"

        _ov_have_listing=off
        if [ "${SHARED_CONF_OVERLAY_BROWSE}" = "on" ]; then
            if sc_browse_content "${_ov_dep}" > "${_ov_list}" 2>/dev/null; then
                _ov_have_listing=on
            else
                if [ "${SHARED_CONF_OVERLAY_DEPLOYMENTS}" = "auto" ]; then
                    sc_log "browse-content できないため対象外: ${_ov_dep}"
                    continue
                fi
                sc_err "browse-content に失敗しました: ${_ov_dep}"
                _ov_rc_all=1
                continue
            fi
        fi

        # 各エントリについてアーカイブ内パスを決定する
        _ov_content=""
        while IFS="${SC_TABCHR}" read -r _ov_needle _ov_src _ov_ovlpath _ov_fallback; do
            [ -z "${_ov_needle}" ] && continue

            if [ "${_ov_ovlpath}" != "-" ]; then
                # linkmap 4 列目で明示指定されている -> それを使う
                _ov_found="${_ov_ovlpath}"
                if [ "${_ov_have_listing}" = "on" ] && ! grep -qxF -- "${_ov_ovlpath}" "${_ov_list}"; then
                    sc_warn "${_ov_dep}: 明示指定 ${_ov_ovlpath} は配備内容に存在しません (overlay は新規ファイルとして追加されます)"
                fi
            elif [ "${_ov_have_listing}" = "on" ]; then
                _ov_found=$(sc_match_paths "${_ov_list}" "${_ov_needle}")
            else
                _ov_found="${_ov_fallback}"
            fi

            [ -z "${_ov_found}" ] && continue

            for _ov_path in ${_ov_found}; do
                sc_log "対象: ${_ov_dep}!/${_ov_path}  <- ${_ov_src}"
                printf '%s\n' "${_ov_path}" >> "${_ov_paths}"
                if [ -z "${_ov_content}" ]; then
                    _ov_content="${_ov_path}=${_ov_src}"
                else
                    _ov_content="${_ov_content},${_ov_path}=${_ov_src}"
                fi
            done
        done < "${SC_WORK}/sources.tsv"

        if [ -z "${_ov_content}" ]; then
            sc_log "対象ファイルなし、スキップ: ${_ov_dep}"
            continue
        fi

        if sc_apply_one "${_ov_dep}" "${_ov_content}"; then
            sc_verify_one "${_ov_dep}" "${_ov_paths}" || _ov_rc_all=1
            _ov_total=$((_ov_total + 1))
        else
            _ov_rc_all=1
        fi
    done

    if [ "${_ov_total}" -eq 0 ]; then
        sc_err "オーバレイを適用したデプロイメントが1つもありません。"
        sc_err "  linkmap のファイル名が配備内容に存在するか、"
        sc_err "  '$0 browse' で実際のアーカイブ内容を確認してください。"
        return 1
    fi

    sc_log "OK: ${_ov_total} 個のデプロイメントに Deployment Overlay を適用しました"
    return "${_ov_rc_all}"
}

# ===========================================================================
# サブコマンド: status / browse / remove
# ===========================================================================
sc_list_overlays() {
    _ov_rc=0
    _ov_out=$(sc_cli ':read-children-names(child-type=deployment-overlay)') || _ov_rc=$?
    [ "${_ov_rc}" -ne 0 ] && return 1
    # このスクリプトが作った overlay (プレフィクス一致) だけを返す。
    # remove がここの結果を消すので、部分一致ではなく前方一致で絞る。
    printf '%s\n' "${_ov_out}" \
        | grep -o '"[^"]*"' | tr -d '"' \
        | grep -v -E '^(outcome|success|result|failure-description)$' \
        | while IFS= read -r _ov_o; do
              case "${_ov_o}" in
                  "${SHARED_CONF_OVERLAY_NAME}-"?*) printf '%s\n' "${_ov_o}" ;;
              esac
          done
}

sc_cmd_status() {
    sc_wait_ready || return 1
    _ov_names=$(sc_list_overlays) || { sc_err "overlay の一覧取得に失敗しました"; return 1; }
    if [ -z "${_ov_names}" ]; then
        sc_log "このスクリプトが管理する overlay はまだありません (prefix: ${SHARED_CONF_OVERLAY_NAME}-)"
        return 0
    fi
    for _ov_name in ${_ov_names}; do
        sc_log "--- ${_ov_name} ---"
        sc_cli "deployment-overlay list-content --name=${_ov_name}" | sed -e 's/^/  content | /'
        sc_cli "deployment-overlay list-links   --name=${_ov_name}" | sed -e 's/^/  link    | /'
    done
    return 0
}

sc_cmd_browse() {
    sc_wait_ready || return 1
    if [ -n "${2:-}" ]; then
        _ov_deps="$2"
    else
        _ov_deps=$(sc_list_deployments) || return 1
    fi
    for _ov_dep in ${_ov_deps}; do
        sc_log "--- deployment browse-content --name=${_ov_dep} ---"
        if ! sc_browse_content "${_ov_dep}" | sed -e 's/^/  | /'; then
            sc_warn "browse-content できません: ${_ov_dep}"
        fi
    done
    return 0
}

sc_cmd_remove() {
    sc_wait_ready || return 1
    _ov_names=$(sc_list_overlays) || { sc_err "overlay の一覧取得に失敗しました"; return 1; }
    if [ -z "${_ov_names}" ]; then
        sc_log "削除対象の overlay はありません"
        return 0
    fi
    _ov_rd=""
    [ "${SHARED_CONF_OVERLAY_REDEPLOY}" = "on" ] && _ov_rd=" --redeploy-affected"
    _ov_rc_all=0
    for _ov_name in ${_ov_names}; do
        sc_cli_run "overlay 削除: ${_ov_name}" \
            "deployment-overlay remove --name=${_ov_name}${_ov_rd}" || _ov_rc_all=1
    done
    return "${_ov_rc_all}"
}

# ===========================================================================
# エントリポイント
# ===========================================================================
if [ "${SHARED_CONF_OVERLAY}" != "on" ] && [ "${SC_SUBCMD}" != "browse" ]; then
    sc_log "SHARED_CONF_OVERLAY=off のため何もしません (有効化するには on を指定)"
    exit 0
fi

case "${SC_SUBCMD}" in
    apply)   sc_cmd_apply; exit $? ;;
    status)  sc_cmd_status; exit $? ;;
    browse)  sc_cmd_browse "$@"; exit $? ;;
    remove)  sc_cmd_remove; exit $? ;;
    startup)
        _ov_rc=0
        sc_cmd_apply || _ov_rc=$?
        if [ "${_ov_rc}" -ne 0 ]; then
            if [ "${SHARED_CONF_OVERLAY_STRICT}" = "on" ]; then
                sc_err "Deployment Overlay の適用に失敗しました。"
                sc_err "SHARED_CONF_OVERLAY_STRICT=on のためコンテナを停止します (PID 1 に SIGTERM)。"
                kill -TERM 1 2>/dev/null || true
            else
                sc_err "Deployment Overlay の適用に失敗しましたが、"
                sc_err "SHARED_CONF_OVERLAY_STRICT=off のためアプリケーションはそのまま動作します。"
                sc_err "設定はアーカイブ内の元の内容が使われている点に注意してください。"
            fi
        fi
        exit "${_ov_rc}" ;;
    *)
        sc_err "不明なサブコマンドです: ${SC_SUBCMD}  (apply|startup|status|browse|remove)"
        exit 1 ;;
esac
