#!/usr/bin/env bash
# ============================================================================
# test/stub/jboss-cli.sh -- jboss-cli.sh のスタブ (selftest-overlay.sh 専用)
# ============================================================================
# 実 JBoss EAP なしで deployment-overlay.sh を検証するための偽 CLI。
# 実装しているのは deployment-overlay.sh が実際に叩くコマンドだけ:
#
#   :read-attribute(name=server-state)
#   :read-children-names(child-type=deployment-overlay)
#   deployment list
#   deployment browse-content --name=<dep>
#   deployment-overlay add|upload|link|redeploy-affected|remove|list-content|list-links
#
# 状態は $STUB_STATE 配下に持つ:
#   deployments          配備済みデプロイメント名 (1行1件)
#   server-state         "running" など (省略時 running)
#   content/<dep>.txt    そのデプロイメントのアーカイブ内容 (1行1パス / 末尾 / はディレクトリ)
#   overlays/<name>.content   "アーカイブ内パス=ローカルパス" (1行1件)
#   overlays/<name>.links     リンク済みデプロイメント名 (1行1件)
#   calls.log            受け取ったコマンドの記録 (検証用)
#   redeploy.log         --redeploy-affected / redeploy-affected の記録
#   fail-pattern         この文字列を含むコマンドを失敗させる (異常系テスト用)
# ============================================================================
set -uo pipefail

: "${STUB_STATE:?STUB_STATE が未設定です}"
mkdir -p "$STUB_STATE/overlays" "$STUB_STATE/content"

cmd=""
for a in "$@"; do
    case "$a" in
        --command=*)  cmd="${a#--command=}" ;;
        --commands=*) cmd="${a#--commands=}" ;;
    esac
done

echo "$cmd" >> "$STUB_STATE/calls.log"

fail() { echo "{\"outcome\" => \"failed\", \"failure-description\" => \"$1\"}"; exit 1; }

if [ -s "$STUB_STATE/fail-pattern" ]; then
    while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        case "$cmd" in *"$pat"*) fail "injected failure: $pat" ;; esac
    done < "$STUB_STATE/fail-pattern"
fi

# ---- 引数の取り出し ---------------------------------------------------------
name=""; content=""; deps=""; redeploy=0
for tok in $cmd; do
    case "$tok" in
        --name=*)            name="${tok#--name=}" ;;
        --content=*)         content="${tok#--content=}" ;;
        --deployments=*)     deps="${tok#--deployments=}" ;;
        --redeploy-affected) redeploy=1 ;;
    esac
done

ovl_content="$STUB_STATE/overlays/${name}.content"
ovl_links="$STUB_STATE/overlays/${name}.links"

note_redeploy() {
    [ "$redeploy" -eq 1 ] || return 0
    [ -f "$ovl_links" ] && cat "$ovl_links" >> "$STUB_STATE/redeploy.log"
    return 0
}

case "$cmd" in

    ':read-attribute(name=server-state)')
        state="running"
        [ -s "$STUB_STATE/server-state" ] && state=$(cat "$STUB_STATE/server-state")
        echo "{"
        echo "    \"outcome\" => \"success\","
        echo "    \"result\" => \"${state}\""
        echo "}"
        ;;

    ':read-children-names(child-type=deployment-overlay)')
        echo "{"
        echo "    \"outcome\" => \"success\","
        echo "    \"result\" => ["
        for f in "$STUB_STATE"/overlays/*.content; do
            [ -e "$f" ] || continue
            b=$(basename "$f" .content)
            echo "        \"${b}\","
        done
        echo "    ]"
        echo "}"
        ;;

    'deployment list')
        # 実 CLI と同様、名前を空白区切りで並べて出す
        tr '\n' ' ' < "$STUB_STATE/deployments"
        echo
        ;;

    'deployment browse-content '*)
        f="$STUB_STATE/content/${name}.txt"
        [ -f "$f" ] || fail "WFLYCTL0216: Management resource '[(\"deployment\" => \"${name}\")]' not found"
        cat "$f"
        ;;

    'deployment-overlay add '*)
        [ -n "$name" ] || fail "--name is missing"
        [ -f "$ovl_content" ] && fail "WFLYCTL0212: Duplicate resource [(\"deployment-overlay\" => \"${name}\")]"
        : > "$ovl_content"
        printf '%s\n' "$content" | tr ',' '\n' | sed '/^$/d' >> "$ovl_content"
        : > "$ovl_links"
        printf '%s\n' "$deps" | tr ',' '\n' | sed '/^$/d' >> "$ovl_links"
        note_redeploy
        echo '{"outcome" => "success"}'
        ;;

    'deployment-overlay upload '*)
        [ -f "$ovl_content" ] || fail "WFLYCTL0216: overlay '${name}' not found"
        # 同じアーカイブ内パスは差し替え、無ければ追加
        printf '%s\n' "$content" | tr ',' '\n' | sed '/^$/d' | while IFS= read -r pair; do
            p="${pair%%=*}"
            grep -v "^${p}=" "$ovl_content" > "$ovl_content.new" 2>/dev/null || true
            mv "$ovl_content.new" "$ovl_content"
            echo "$pair" >> "$ovl_content"
        done
        echo '{"outcome" => "success"}'
        ;;

    'deployment-overlay link '*)
        [ -f "$ovl_content" ] || fail "WFLYCTL0216: overlay '${name}' not found"
        touch "$ovl_links"
        added=0
        for d in $(printf '%s' "$deps" | tr ',' ' '); do
            if ! grep -qx "$d" "$ovl_links"; then
                echo "$d" >> "$ovl_links"
                added=1
            fi
        done
        # 既にすべてリンク済みなら実 CLI 同様エラーを返す
        [ "$added" -eq 0 ] && fail "WFLYCTL0212: Duplicate resource"
        echo '{"outcome" => "success"}'
        ;;

    'deployment-overlay redeploy-affected '*)
        [ -f "$ovl_content" ] || fail "WFLYCTL0216: overlay '${name}' not found"
        cat "$ovl_links" >> "$STUB_STATE/redeploy.log"
        echo '{"outcome" => "success"}'
        ;;

    'deployment-overlay remove '*)
        [ -f "$ovl_content" ] || fail "WFLYCTL0216: overlay '${name}' not found"
        note_redeploy
        rm -f "$ovl_content" "$ovl_links"
        echo '{"outcome" => "success"}'
        ;;

    'deployment-overlay list-content '*)
        [ -f "$ovl_content" ] || fail "WFLYCTL0216: overlay '${name}' not found"
        cut -d= -f1 "$ovl_content"
        ;;

    'deployment-overlay list-links '*)
        [ -f "$ovl_links" ] || fail "WFLYCTL0216: overlay '${name}' not found"
        cat "$ovl_links"
        ;;

    *)
        fail "unsupported command in stub: ${cmd}"
        ;;
esac
exit 0
