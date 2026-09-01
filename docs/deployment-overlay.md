# 追加機能: Deployment Overlays で配備済み WAR の設定ファイルを上書きする

symlink 機構 (メイン実装) は `/webapp/webapp9mXX` を**展開済みディレクトリ**として
読むアプリにしか効かない。WAR アーカイブとして配備され、JBoss VFS が
`jboss.server.temp.dir` に展開したコピーを読む形態では、
symlink はビルド時のコピーに巻き取られてしまい意味がなくなる
([docs/design.md](design.md) §6.3 の 3 番目のケース)。

この穴を埋めるのが **Deployment Overlays** による上書き。
`jboss-cli.sh` の管理操作で、**配備済み WAR アーカイブを一切書き換えずに**
アーカイブ内の任意パスを外部ファイルの内容で差し替える。

```
EFS 上の実体   /mnt/logs/tmp/date_config.properties      ← EC2 から編集する 1 ファイル
      │
      │  deployment-overlay add --content=<アーカイブ内パス>=/mnt/logs/tmp/date_config.properties
      ↓
配備済み WAR   intra-web-front.war!/WEB-INF/classes/jp/co/sample/base/date_config.properties
               ^^^ .war ファイル自体は無変更。管理レイヤで上書きされる
```

**既定は off。** ビルド引数 `--build-arg SHARED_CONF_OVERLAY=on` を渡したときだけ有効になる。
symlink 機構 (`SHARED_CONF_SYMLINK`) とは完全に独立していて、4 通りの組み合わせがすべて動く。

---

## 1. symlink 機構との関係

| | `SYMLINK=off` `OVERLAY=off`<br>(**既定**) | `SYMLINK=on` `OVERLAY=off` | `SYMLINK=off` `OVERLAY=on` | `SYMLINK=on` `OVERLAY=on` |
|---|---|---|---|---|
| イメージ内のファイル | 実ファイルのまま | EFS への symlink | 実ファイルのまま | EFS への symlink |
| 展開ディレクトリを読むアプリ | イメージの値 | **EFS の値** | イメージの値 | **EFS の値** |
| WAR アーカイブを読むアプリ | アーカイブの値 | アーカイブの値 | **EFS の値** | **EFS の値** |
| EFS への依存 | なし | あり | あり (`SOURCE=link` なら無し) | あり |
| 反映タイミング | 再ビルド | タスク再起動 | overlay 再適用 | 両方 |

- 展開ディレクトリ形態と WAR 形態が混在しているなら **両方 on** が正解。
- どちらの形態か確定していないなら、まず `deployment-overlay.sh browse` で
  実際の配備内容を見てから決める (§5)。

### `SYMLINK=off` + `OVERLAY=on` のときの EFS 実体

このとき、イメージ内のファイルは実ファイルのまま残る (symlink 化されない) が、
オーバレイ元 (`SOURCE=auto` の既定) は EFS 上の実体を優先する。
そのため entrypoint は **EFS のマウントを待ち、実体が無ければ
イメージ内の実ファイルからシードする**。
`SHARED_CONF_SEED=off` にすればシードしない (その場合 `auto` は
イメージ内のファイルにフォールバックするので、実質「共有なし」になる)。

EFS に一切依存させたくないなら `SHARED_CONF_OVERLAY_SOURCE=link` にする。
このときは EFS 待ちもシードも行わない。

---

## 2. 処理の流れ

```
shared-conf-entrypoint.sh
  ├─ (SYMLINK=on なら) EFS 待ち → 実体をシード → リンク検証
  ├─ (OVERLAY=on かつ OVERLAY_AUTO=on なら)
  │     deployment-overlay.sh startup &      ← バックグラウンドで起動
  └─ exec standalone.sh                      ← JBoss が PID 1 になる

deployment-overlay.sh startup  (バックグラウンド)
  ├─ 1. サーバが running になるまで待つ
  │      jboss-cli> :read-attribute(name=server-state)
  ├─ 2. linkmap の各エントリについてオーバレイ元ファイルを決める
  │      SOURCE=auto → EFS 上の実体を優先、無ければイメージ内のファイル
  ├─ 3. 配備済みデプロイメントを列挙する
  │      jboss-cli> deployment list
  ├─ 4. 各デプロイメントの中身を実測し、対象ファイルのパスを特定する ★
  │      jboss-cli> deployment browse-content --name=intra-web-front.war
  │      → WEB-INF/classes/jp/co/sample/base/date_config.properties がヒット
  ├─ 5. デプロイメント単位で overlay を作成/更新する
  │      jboss-cli> deployment-overlay add --name=shared-conf-intra-web-front.war \
  │                  --content=WEB-INF/classes/.../date_config.properties=/mnt/logs/tmp/date_config.properties \
  │                  --deployments=intra-web-front.war --redeploy-affected
  └─ 6. 登録されたことを検証する
         jboss-cli> deployment-overlay list-content --name=...
         jboss-cli> deployment-overlay list-links   --name=...
```

overlay は **デプロイメントごとに 1 つ** (`shared-conf-<デプロイメント名>`) 作る。
1 つの overlay を複数デプロイメントにリンクすると、
「A には無いパスの content が A に新規ファイルとして追加される」
という副作用が起きるため、意図的に分けている。

---

## 3. `deployment browse` は使えるか — 検討結果

**結論: `deployment browse-content` 単独ではオーバレイできない (読み取り専用のため)。
ただし「アーカイブのどこにそのファイルが入っているか」を実測する用途では極めて有効で、
本実装では既定の探索手段として採用した。**

### 3.1 何ができて、何ができないか

| コマンド | 種別 | この機能に対して |
|---|---|---|
| `deployment browse-content --name=X` | 読み取り | デプロイメント内の全パスを列挙する。**上書きはできない** |
| `deployment-overlay add/upload/link` | 書き込み | 実際に上書きを行うのはこちら |
| `/deployment=X:read-content(path=P)` | 読み取り | 個別ファイルの中身を取得する (調査に有用) |

`browse-content` は `deployment-overlay` の代替にはならない。両者は役割が違う。

### 3.2 それでも browse-content を入れた理由

Deployment Overlay の `--content=<アーカイブ内パス>=<ファイル>` は
**アーカイブ内パスが 1 文字でも違うと無言で失敗する** —
正確には「失敗しない」ことが問題で、存在しないパスを指定すると
**エラーにならず、そのパスに新規ファイルが追加されるだけ**になる。
アプリは元の設定を読み続け、運用は「反映されない」とだけ気づく。

展開ツリー上のパス (`servlets/jp/co/sample/base/date_config.properties`) と
WAR 内のパス (`WEB-INF/classes/jp/co/sample/base/date_config.properties`) は
一般に一致しないので、決め打ちは事故のもとになる。

`browse-content` で実際の配備内容を列挙して突き合わせれば、

- アーカイブ内の**本当のパス**が分かる
- **同名ファイルが複数の WAR に入っていても全部拾える** (ご要望の「同名ファイルも対象」)
- 対象ファイルを持たないデプロイメントには**触らない** (誤注入を防ぐ)
- `deployment list` のパース結果が名前として不正なら browse が失敗するので、
  結果的に**デプロイメント名の検証にもなる**

`SHARED_CONF_OVERLAY_BROWSE=off` にすれば従来どおりパス決め打ちにもできるが、
その場合は linkmap の 4 列目 (`OVERLAY_PATH`) で明示することを強く推奨する。

### 3.3 browse-content で「適用結果」は確認できない

`browse-content` が返すのはそのデプロイメント自身のコンテンツであり、
overlay は配備時に別レイヤとして重ねられる。
したがって **overlay を適用しても browse-content の出力は変わらない**。
適用結果の確認は次で行う (本実装の `sc_verify_one` もこれを使っている)。

```bash
# overlay が登録され、対象デプロイメントにリンクされているか
/opt/app/shared-conf/bin/deployment-overlay.sh status

# 実際にアプリが読んでいる値まで確認したいなら、アプリの挙動で見る
```

### 3.4 前提バージョン

`deployment browse-content` は **JBoss EAP 7.1 / WildFly 11 以降**。
それより古い場合は `SHARED_CONF_OVERLAY_BROWSE=off` + `OVERLAY_PATH` 明示で運用する。
管理対象外 (unmanaged / デプロイメントスキャナ経由の外部パス) のデプロイメントでは
`browse-content` が失敗することがある。その場合このスクリプトは
`SHARED_CONF_OVERLAY_DEPLOYMENTS=auto` ならそのデプロイメントをスキップし、
明示指定されていればエラーにする。

---

## 4. 前提条件 (readonlyRootFilesystem との関係) ★重要

`deployment-overlay` は管理操作なので、**JBoss 側に書き込みが発生する**。

| 書き込み先 | 用途 |
|---|---|
| `$JBOSS_HOME/standalone/data/content/...` | overlay のコンテンツ (アップロードされたファイルのコピー) |
| `$JBOSS_HOME/standalone/configuration/standalone.xml` | `<deployment-overlays>` の定義 |

`readonlyRootFilesystem=true` では、この 2 つが書き込み可能でなければ
`deployment-overlay add` は失敗する。対処は次のいずれか。

- **(a)** `jboss.server.base.dir` を書き込み可能なパス (空ボリュームのマウント先) に向ける
- **(b)** 起動時に `$JBOSS_HOME/standalone` の内容を空ボリュームへコピーしてから起動する

`taskdef/taskdef-intra-web.example.json` に `eap-standalone` ボリュームの例をコメント付きで入れてある。

> 既に WAR を実行時にデプロイできている構成なら、JBoss はコンテンツリポジトリに
> 書けているはずなので、多くの場合そのまま動く。
> `deployment-overlay.sh` は起動時にこの 2 つのディレクトリの書き込み可否を
> 事前チェックし、書けない場合は WARN で理由を先に出す。

管理インタフェースにも接続できる必要がある。

```
CMD ["/opt/eap/bin/standalone.sh", "-b", "0.0.0.0", "-bmanagement", "0.0.0.0"]
```

コンテナ内から `127.0.0.1:9990` に繋ぐので、`-bmanagement 127.0.0.1` でも構わない
(`SHARED_CONF_CLI_CONTROLLER` を合わせること)。
**管理ポートを外部に公開する必要はない。** セキュリティグループ / portMappings には出さないこと。

管理層に認証がかかっている場合は同一ホスト・同一 uid からの
ローカル認証で通るのが普通だが、通らない場合は
`SHARED_CONF_CLI_USER` / `SHARED_CONF_CLI_PASSWORD` を渡す
(タスク定義の `secrets` 経由を推奨)。

---

## 5. 使い方

### 5.1 ビルド

```bash
# WAR にも反映させる (symlink 共有も併用する構成)
docker build --build-arg APP_ROOT=/webapp/webapp9mf02 \
             --build-arg SHARED_CONF_SYMLINK=on \
             --build-arg SHARED_CONF_OVERLAY=on \
             -t <repo>/intra-web-front:1.0.0 .
```

ビルドログ:

```
[shared-conf/build] SHARED_CONF_SYMLINK  = on
[shared-conf/build] SHARED_CONF_OVERLAY  = on
[shared-conf/build] Deployment Overlays は実行時に適用します (ビルド時のイメージ変更なし)
[shared-conf/build]   適用スクリプト: /opt/app/shared-conf/bin/deployment-overlay.sh
```

overlay はビルド時にイメージを変更しない。
ビルド時にやるのは「値の妥当性」と「`deployment-overlay.sh` の COPY 漏れ」の検出だけ。

### 5.2 起動時 (自動)

`SHARED_CONF_OVERLAY_AUTO=on` (既定) なら entrypoint が自動で適用する。
コンテナログ:

```
[shared-conf/init] Deployment Overlay をバックグラウンドで適用します (サーバ起動後)
[shared-conf/overlay] サーバ起動を確認しました (12s)
[shared-conf/overlay] オーバレイ元: /mnt/logs/tmp/date_config.properties  (照合キー: date_config.properties)
[shared-conf/overlay] 対象: intra-web-front.war!/WEB-INF/classes/jp/co/sample/base/date_config.properties  <- /mnt/logs/tmp/date_config.properties
[shared-conf/overlay] overlay 作成: shared-conf-intra-web-front.war -> intra-web-front.war
[shared-conf/overlay] 検証OK: intra-web-front.war <- shared-conf-intra-web-front.war (1 パス)
[shared-conf/overlay] 対象ファイルなし、スキップ: other.war
[shared-conf/overlay] OK: 2 個のデプロイメントに Deployment Overlay を適用しました
```

### 5.3 調査: 実際の配備内容を見る

適用前に必ず一度は見ておくこと。`browse` は `SHARED_CONF_OVERLAY=off` でも使える。

```bash
aws ecs execute-command --cluster <cluster> --task <task-id> --container front \
  --interactive --command "/opt/app/shared-conf/bin/deployment-overlay.sh browse"

# 特定のデプロイメントだけ
... --command "/opt/app/shared-conf/bin/deployment-overlay.sh browse intra-web-front.war"
```

### 5.4 運用: 設定を編集したあとの再適用

**overlay の内容は `add` / `upload` した時点のコピーがコンテンツリポジトリに取り込まれる。
EFS 側を編集しても、再適用するまで反映されない。** ここがメイン実装との一番大きな違い。

```bash
# 1) EC2 で編集
sudo ./ec2/edit-shared-conf.sh --set date.format=yyyy-MM-dd /mnt/logs/tmp/date_config.properties

# 2) コンテナ内で再適用 (該当デプロイメントだけが再デプロイされる)
aws ecs execute-command --cluster <cluster> --task <task-id> --container front \
  --interactive --command "/opt/app/shared-conf/bin/deployment-overlay.sh apply"
```

サービス全体の再デプロイ (`update-service --force-new-deployment`) をせずに
設定を反映できるのは、この機構の実用上の最大の利点。
逆に、再デプロイでも反映される (起動時に自動適用されるため) ので、
どちらの運用でも整合する。

タスクが複数あるなら全タスクに対して実行すること。

```bash
for t in $(aws ecs list-tasks --cluster <cluster> --service-name intra-web \
             --query 'taskArns[]' --output text); do
  aws ecs execute-command --cluster <cluster> --task "$t" --container front \
    --command "/opt/app/shared-conf/bin/deployment-overlay.sh apply" --interactive
done
```

### 5.5 状態確認 / 切り戻し

```bash
# 今どの overlay が効いているか
/opt/app/shared-conf/bin/deployment-overlay.sh status

# このスクリプトが作った overlay を全部消す (アーカイブ元の内容に戻る)
/opt/app/shared-conf/bin/deployment-overlay.sh remove
```

イメージ側の切り戻しは `--build-arg SHARED_CONF_OVERLAY=off` で再ビルド、
または (実行時機構なので) タスク定義の `SHARED_CONF_OVERLAY=off` を入れて再デプロイ。

---

## 6. パラメータ

| 変数 | 既定値 | 説明 |
|---|---|---|
| `SHARED_CONF_OVERLAY` | `off` | **この機能全体の on/off。ビルド引数で on にすると有効** |
| `SHARED_CONF_OVERLAY_AUTO` | `on` | 起動時に自動適用するか。`off` なら手動 (`apply`) のみ |
| `SHARED_CONF_OVERLAY_NAME` | `shared-conf` | overlay 名のプレフィクス (`<prefix>-<デプロイメント名>`) |
| `SHARED_CONF_OVERLAY_SOURCE` | `auto` | オーバレイ元。`auto`=EFS 実体優先→イメージ内 / `target`=EFS 実体固定 / `link`=イメージ内固定 |
| `SHARED_CONF_OVERLAY_MATCH` | `name` | 突き合わせ方。`name`=**ファイル名一致 (同名ファイルを全部拾う)** / `path`=linkmap 相対パスの末尾一致 |
| `SHARED_CONF_OVERLAY_BROWSE` | `on` | `deployment browse-content` で配備内容を実測するか |
| `SHARED_CONF_OVERLAY_DEPLOYMENTS` | `auto` | `auto`=`deployment list` で列挙 / `a.war,b.war`=明示指定 |
| `SHARED_CONF_OVERLAY_REDEPLOY` | `on` | `--redeploy-affected` を付けるか (off だと次回再起動まで反映されない) |
| `SHARED_CONF_OVERLAY_STRICT` | `off` | `startup` 時、適用に失敗したらコンテナを停止するか (PID 1 に SIGTERM) |
| `SHARED_CONF_OVERLAY_DRYRUN` | `off` | 実行せず発行予定の CLI コマンドを表示する |
| `SHARED_CONF_OVERLAY_WAIT` | `180` | サーバが running になるのを待つ最大秒数 |
| `SHARED_CONF_OVERLAY_INTERVAL` | `3` | 上記のポーリング間隔 (秒) |
| `JBOSS_HOME` | `/opt/eap` | jboss-cli.sh の探索基点 |
| `SHARED_CONF_CLI` | `${JBOSS_HOME}/bin/jboss-cli.sh` | CLI のフルパス |
| `SHARED_CONF_CLI_CONTROLLER` | `remote+http://127.0.0.1:9990` | 接続先 |
| `SHARED_CONF_CLI_USER` / `_PASSWORD` | (未設定) | 管理認証が必要な場合のみ |

`on`/`off` 系は `true`/`false`、`1`/`0`、`yes`/`no` でも指定できる
(解釈できない値はエラー)。`SOURCE` / `MATCH` の列挙値も同様に、
タイプミスは黙って既定値に落とさずエラーにする。

### linkmap の 4 列目 (`OVERLAY_PATH`)

アーカイブ内パスを固定したい場合だけ使う。既定 (`-`) は browse-content で自動探索。

```
${APP_ROOT}/servlets/jp/co/sample/base/date_config.properties  ${SHARED_CONF_DIR}/date_config.properties  -  WEB-INF/classes/jp/co/sample/base/date_config.properties
```

アーカイブ内の**相対**パスなので、先頭 `/` を付けるとエラーになる。

---

## 7. 制約と注意点

### 7.1 反映は「再適用」が必要 (§5.4)

overlay はスナップショットコピー。symlink 機構のような「常に最新を読む」性質はない。
両方 on にしている場合、**展開ディレクトリ側は編集が即座に見えるのに
WAR 側は再適用するまで古い**、というズレが起きうる。
運用手順は「編集 → 全タスクで `apply`」に統一しておくこと。

### 7.2 `--redeploy-affected` による再デプロイ

適用のたびに対象デプロイメントが再デプロイされる (数秒〜)。
起動時の自動適用では、デプロイ済みの WAR が 1 回余分に再デプロイされることになる。
これが許容できない場合は `SHARED_CONF_OVERLAY_REDEPLOY=off` にして、
反映タイミングを次のタスク再起動に寄せる。

### 7.3 バックグラウンドプロセスとゾンビ

`exec` 後は JBoss が PID 1 になるが、JVM は任意の子プロセスを reap しないため、
適用スクリプトの終了後に短命なゾンビが 1 つ残ることがある。
プロセステーブルのエントリ 1 個分で、実害はない。

### 7.4 失敗時の既定はコンテナ停止「しない」

`SHARED_CONF_OVERLAY_STRICT=off` (既定) では、適用に失敗しても
アプリはアーカイブ内の元の設定で動き続ける。
ログに ERROR が出るだけなので、**CloudWatch Logs で
`[shared-conf/overlay][ERROR]` を拾うアラームを入れておくこと。**
「失敗したら起動させたくない」なら `on` にする (PID 1 に SIGTERM を送り、ECS が異常として扱う)。

### 7.5 パスにカンマ・空白を含められない

`--content=a=b,c=d` はカンマ区切り、デプロイメント名は空白区切りで扱っている。
設定ファイルのパスやデプロイメント名にカンマ・空白を含めないこと。

### 7.6 standalone 構成のみ

`:read-attribute(name=server-state)` と `deployment list` は standalone 前提。
managed domain で使う場合はアドレス指定 (`/host=.../server=...`) が必要になるため、
本スクリプトはそのままでは使えない。

---

## 8. 検証

```bash
bash test/selftest-overlay.sh
```

実 JBoss なしで、`test/stub/jboss-cli.sh` を偽 CLI として使い次を検証している
(63 項目 all pass):

- 既定は off (symlink / overlay とも何もしない)
- `browse-content` でアーカイブ内の実パスを特定する
- **複数 WAR に入っている同名ファイルを全部オーバレイする**
- 対象ファイルを持たないデプロイメントには触らない
- オーバレイ元として EFS 上の実体が使われる
- 2 回目以降は `add` ではなく `upload` + `link` + `redeploy-affected` (冪等)
- `match=path` / `browse=off` / 4 列目明示 の各モード
- `--redeploy-affected` の有無
- dry-run / status / browse / remove
- CLI 失敗・起動タイムアウト・対象ゼロ・不正値で非0終了
- entrypoint が起動コマンドを `exec` しつつ overlay を適用する
