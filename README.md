# 共有プロパティファイル機構 (ECS Fargate / readonlyRootFilesystem=true)

4 サービス (`intra-api` / `inter-api` / `sf-api` / `intra-web`) × front/back = 8 コンテナが、
EFS 上の **1 ファイル**を参照する仕組み。EC2 (RHEL 9.8) から編集でき、
ECS タスクを再起動しても内容は維持される。

```
front:  /webapp/webapp9mf02/servlets/jp/co/sample/base/date_config.properties  ─┐
back :  /webapp/webapp9mb02/servlets/jp/co/sample/base/date_config.properties  ─┤ symlink
                                                                               ↓
                            /mnt/logs/tmp/date_config.properties  ← 実体 (EFS / 6301:6302)
                                                                               ↑
                                       EC2 (RHEL 9.8) からここを編集する
```

**タスク定義の mountPoints / volumes は変更不要。** 既存の `/mnt/logs` マウントをそのまま流用する。

実現方式は独立した 2 つあり、**どちらもビルド引数で on にしたときだけ有効**になる (既定はどちらも off)。

| 機構 | ビルド引数 | 効く相手 |
|---|---|---|
| **symlink 共有** | `SHARED_CONF_SYMLINK=on` | `/webapp/webapp9mXX` を**展開済みディレクトリ**として読むアプリ |
| **Deployment Overlays** | `SHARED_CONF_OVERLAY=on` | **WAR アーカイブとして配備**され、JBoss VFS 経由で読むアプリ |

両方 on にすれば両形態をカバーできる。
overlay 側の詳細は [docs/deployment-overlay.md](docs/deployment-overlay.md)。

---

## 中核となる制約

`readonlyRootFilesystem=true` のため `/webapp` 配下には実行時に書き込めない。
Fargate は `tmpfs` 非対応、空ボリュームは同ディレクトリの他ファイルをマスクしてしまう。

→ **シンボリックリンクはイメージビルド時に焼き込み、実体の生成だけを実行時に行う。**

symlink はアクセス時に遅延解決されるため、ビルド時点で `/mnt/logs` が無く dangling でも問題ない。
検討した代替案と却下理由は [docs/design.md](docs/design.md) の §2 を参照。

ただし symlink は「アプリが展開済みディレクトリを直接読む」場合にしか効かない。
WAR アーカイブが `jboss.server.temp.dir` に展開されるデプロイ形態では
**展開時点のコピー**が読まれるため symlink の意味がなくなる (design.md §6.3)。
この穴を埋めるのが Deployment Overlays による上書き。

---

## ファイル構成

```
image/
  linkmap.conf                    ★ 共有するファイルの一覧 (front/back 共通)
  linkmap.alt-a.conf.example         ALT-A 用 (docs/alt-per-service-path.md)
  linkmap.alt-b.conf.example         ALT-B 用
  bin/
    linkmap-lib.sh                   linkmap のパーサ (ビルド時・実行時で共用)
    build-shared-links.sh         ★ 【ビルド時/root】symlink をイメージに焼き込む
    shared-conf-entrypoint.sh     ★ 【実行時/6301】実体を初回生成し、検証して exec
    deployment-overlay.sh         ★ 【実行時/6301】jboss-cli で WAR に overlay を適用
  Dockerfile.snippet                 既存 Dockerfile への追記差分
  Dockerfile.front.example           全体像がわかる参考 Dockerfile

ec2/
  init-shared-conf.sh             ★ 【EC2】/mnt/logs/tmp を初期構築
  edit-shared-conf.sh             ★ 【EC2】所有者・権限を保ったまま安全に編集
  init-shared-conf-per-service.sh    【EC2】ALT-B 用: 8 箇所を一括 init/sync/diff

taskdef/
  taskdef-intra-web.example.json     タスク定義の例 (変更点はコメントで明示)
  verify-taskdef.sh               ★ front/back の rootDirectory 一致を事前チェック

test/
  selftest.sh                        symlink=on の E2E 検証 (実 EFS 不要)
  selftest-nolink.sh                 symlink=off (既定) の検証
  selftest-overlay.sh                Deployment Overlays の検証 (実 JBoss 不要)
  selftest-alt.sh                    ALT-A / ALT-B の検証
  stub/jboss-cli.sh                  selftest-overlay.sh 用の偽 jboss-cli

docs/
  design.md                          設計根拠・却下した代替案・運用上の注意
  deployment-overlay.md              Deployment Overlays の設計・前提条件・運用
  alt-per-service-path.md            【追加検討】実体をログツリー配下に置く場合
```

---

## 導入手順

### 0. 事前チェック

```bash
# front/back が同一 EFS・同一 rootDirectory を見ているか (ここがずれると共有されない)
./taskdef/verify-taskdef.sh intra-api inter-api sf-api intra-web

# 実装ロジックの検証 (実 EFS / 実 JBoss 不要)
bash test/selftest.sh
bash test/selftest-nolink.sh
bash test/selftest-overlay.sh
```

### 1. EC2 側の初期構築 (1 回だけ)

```bash
sudo ./ec2/init-shared-conf.sh
# -> /mnt/logs/tmp を 6301:6302 / mode 2775 で作成
```

### 2. イメージのビルド

`image/Dockerfile.snippet` を既存 Dockerfile の **アプリ資材 COPY より後ろ**に追記する。

```bash
# 既定 (何も変わらない従来どおりのイメージ)
docker build --build-arg APP_ROOT=/webapp/webapp9mf02 -t <repo>/intra-web-front:1.0.0 .

# symlink 共有あり
docker build --build-arg APP_ROOT=/webapp/webapp9mf02 \
             --build-arg SHARED_CONF_SYMLINK=on \
             -t <repo>/intra-web-front:1.0.0-shared .

# symlink 共有 + WAR への overlay
docker build --build-arg APP_ROOT=/webapp/webapp9mf02 \
             --build-arg SHARED_CONF_SYMLINK=on \
             --build-arg SHARED_CONF_OVERLAY=on \
             -t <repo>/intra-web-front:1.0.0-full .
```

`SHARED_CONF_SYMLINK=on` のビルドログに以下が出れば成功:

```
[shared-conf/build] default をイメージから退避  : /webapp/.../date_config.properties -> /opt/app/shared-conf/defaults/...
[shared-conf/build] symlink 作成               : /webapp/.../date_config.properties -> /mnt/logs/tmp/date_config.properties
[shared-conf/build] OK: 全エントリのシンボリックリンクをイメージに焼き込みました
```

#### symlink の on / off (`SHARED_CONF_SYMLINK`)

同じ Dockerfile のまま、ビルド引数だけで**共有するイメージ / しないイメージ**を作り分けられる。
**既定は `off` (= 共有しない)。** 段階導入・切り戻し・共有が不要なサービスがそのまま既定になる。

| | `off` (既定) | `on` |
|---|---|---|
| ビルド時 | **イメージを書き換えない**。対象が実ファイルとして存在するかの検証のみ | 元ファイルを `defaults/` に退避し、`LINK` を symlink に置換 |
| 実行時 | 検証のみ (**EFS に一切触れない**) → `exec` | EFS マウント待ち → 実体をシード → リンク解決を検証 → `exec` |
| 設定の実体 | イメージ内に 1 つずつ (共有されない) | EFS 上に 1 ファイル (8 コンテナで共有) |
| 設定の変更方法 | イメージ再ビルド | EC2 から編集 → 再デプロイ |
| EFS への依存 | なし | あり (`/mnt/logs` が無いと起動失敗) |

`off` のビルドログ:

```
[shared-conf/build] SHARED_CONF_SYMLINK  = off
[shared-conf/build] symlink は作成しません (共有機構なしのイメージをビルドします)
[shared-conf/build] 実ファイルのまま維持       : /webapp/.../date_config.properties
[shared-conf/build] OK: 全エントリをイメージ内の実ファイルのまま維持しました (SHARED_CONF_SYMLINK=off)
```

**値はビルド時と実行時で一致していなければならない。**
`ARG` の値は `ENV` に固定されてイメージに焼き込まれるので、
タスク定義の `environment` で上書きしないこと。
食い違った場合 (例: `on` で焼いたイメージを `off` で起動) は
entrypoint が検出して起動を中止する (`SHARED_CONF_STRICT=on` のとき)。

#### WAR への上書き (`SHARED_CONF_OVERLAY`)

**既定は `off`。** `on` にすると、起動後に `jboss-cli.sh` の
Deployment Overlays で、**配備済み WAR アーカイブを書き換えずに**
同じ設定ファイルを EFS 上の実体の内容で上書きする。
アーカイブ内のパスは `deployment browse-content` で実測して特定するので、
**同名ファイルが複数の WAR に入っていても全部が対象**になる。

overlay は実行時だけの機構なので、ビルド引数でも
タスク定義の `environment` でも切り替えられる (整合性は崩れない)。

前提条件 (管理インタフェース / JBoss 側の書き込み可能性) と運用手順は
[docs/deployment-overlay.md](docs/deployment-overlay.md) を必ず参照すること。

> **重要**: overlay の内容は適用時点のコピー。EFS 側を編集しても
> `deployment-overlay.sh apply` を再実行するまで反映されない。

### 3. デプロイ

まず `intra-web` 1 サービスだけ先行させ、ECS Exec で実測してから残りを展開する
(手順は [docs/design.md](docs/design.md) §7)。

### 4. 運用: ファイルを編集する

```bash
# エディタで編集
sudo ./ec2/edit-shared-conf.sh /mnt/logs/tmp/date_config.properties

# キーを直接指定して更新
sudo ./ec2/edit-shared-conf.sh --set date.format=yyyy-MM-dd /mnt/logs/tmp/date_config.properties

# 内容表示 / 直近バックアップとの差分
sudo ./ec2/edit-shared-conf.sh --show /mnt/logs/tmp/date_config.properties
sudo ./ec2/edit-shared-conf.sh --diff /mnt/logs/tmp/date_config.properties
```

`vi` で直接編集しないこと。所有者が `root:root` になったり permission が変わって
コンテナから読めなくなる事故が起きる。ラッパは
所有者 6301:6302 / mode 0664 の維持、properties としての構文検証、
バックアップ、原子的な置換 (同一ディレクトリ内 rename) を行う。

> **重要**: アプリが起動時に 1 回だけ `Properties#load` する実装なら、
> 編集だけでは反映されない。ECS サービスの再デプロイが必要
> ([docs/design.md](docs/design.md) §6.1)。
>
> `SHARED_CONF_OVERLAY=on` なら、サービス全体を再デプロイせずに
> コンテナ内で overlay を再適用するだけで反映できる
> ([docs/deployment-overlay.md](docs/deployment-overlay.md) §5.4)。

---

## 共有するファイルを増やす

`image/linkmap.conf` に 1 行足してイメージを再ビルドするだけ。
ビルド時スクリプトと実行時スクリプトが同じマニフェストを読むので、
片方だけ直し忘れる事故が起きない。

```
${APP_ROOT}/servlets/jp/co/sample/base/holiday_config.properties  ${SHARED_CONF_DIR}/holiday_config.properties  -  -
```

第 3 列 (初期値の置き場所) を `-` にすると
`${DEFAULTS_DIR}/<APP_ROOT からの相対パス>` に自動決定されるため、
別ディレクトリの同名ファイルを追加しても衝突しない。

第 4 列は overlay で上書きする**アーカイブ内の相対パス**。
`-` なら `deployment browse-content` で自動探索する (通常は `-` でよい)。

---

## 環境変数

### symlink 機構

| 変数 | 既定値 | 説明 |
|---|---|---|
| `APP_ROOT` | (必須) | `/webapp/webapp9mf02` (front) / `/webapp/webapp9mb02` (back) |
| `SHARED_CONF_SYMLINK` | **`off`** | `on`=symlink を作り EFS 上の1ファイルを共有 / `off`=symlink を作らずイメージ内の実ファイルを使う。**ビルド引数で指定し、実行時も同じ値**にする |
| `SHARED_CONF_DIR` | `/mnt/logs/tmp` | 実体を置くディレクトリ |
| `SHARED_CONF_MOUNT` | 自動判定 | EFS マウントポイント (起動時の待ち合わせ対象) |
| `SHARED_CONF_LINKMAP` | `/opt/app/shared-conf/linkmap.conf` | マニフェストの場所 |
| `DEFAULTS_DIR` | `/opt/app/shared-conf/defaults` | イメージ内の初期値の置き場所 |
| `SHARED_CONF_SEED` | `on` | 実体が無いとき初期値から生成するか |
| `SHARED_CONF_STRICT` | `on` | リンクを解決できないとき起動を中止するか |
| `SHARED_CONF_MODE` | `0664` | 生成する実体の permission |
| `SHARED_CONF_WAIT` | `30` | EFS マウント待ちの最大秒数 |

### Deployment Overlays

| 変数 | 既定値 | 説明 |
|---|---|---|
| `SHARED_CONF_OVERLAY` | **`off`** | overlay 機構全体の on/off |
| `SHARED_CONF_OVERLAY_AUTO` | `on` | 起動時に自動適用するか (`off` なら手動のみ) |
| `SHARED_CONF_OVERLAY_MATCH` | `name` | `name`=同名ファイルを全部拾う / `path`=相対パス末尾一致 |
| `SHARED_CONF_OVERLAY_BROWSE` | `on` | `deployment browse-content` で配備内容を実測するか |
| `SHARED_CONF_OVERLAY_SOURCE` | `auto` | オーバレイ元 (`auto`/`target`/`link`) |
| `SHARED_CONF_OVERLAY_DEPLOYMENTS` | `auto` | 対象デプロイメント (`auto` または `a.war,b.war`) |
| `SHARED_CONF_OVERLAY_REDEPLOY` | `on` | `--redeploy-affected` を付けるか |
| `SHARED_CONF_OVERLAY_STRICT` | `off` | 適用失敗時にコンテナを停止するか |
| `SHARED_CONF_CLI_CONTROLLER` | `remote+http://127.0.0.1:9990` | jboss-cli の接続先 |

全パラメータは [docs/deployment-overlay.md](docs/deployment-overlay.md) §6。

`on` / `off` 系の値は `true`/`false`、`1`/`0`、`yes`/`no` でも指定できる
(解釈できない値は誤設定として起動・ビルドを失敗させる)。

`SHARED_CONF_DIR` は **linkmap と一致していなければならない**
(linkmap 側の `${SHARED_CONF_DIR}` 展開に使われるため)。
Dockerfile の `ENV` で固定しておき、タスク定義では上書きしないのが安全。

---

## 動作保証の要点

`test/selftest.sh` (`SHARED_CONF_SYMLINK=on`) で以下を実機同等に再現して検証済み:

- ビルド時に symlink へ置換され、初期値がイメージ内に退避される
- EFS 未マウント時点では dangling で、マウント後に解決される
- 実体が無ければ初回起動時に生成される
- **8 コンテナ同時起動でも実体は 1 個** (`link(2)` によるアトミックな公開)
- **タスク再起動で編集内容が維持される** (既存があれば絶対に上書きしない)
- EC2 側の編集が front/back 両方から見える
- リンクが解決できない場合は起動を中止する (`SHARED_CONF_STRICT=on`)
- **`SHARED_CONF_SYMLINK` 未指定なら symlink を作らない (既定 off)**

`test/selftest-nolink.sh` では `SHARED_CONF_SYMLINK=off` 側を検証済み:

- symlink が作られず、イメージ内の実ファイルが内容そのままで残る
- EFS が無くても起動でき、EFS 側に何も作らない
- front / back の設定は共有されない (= off の期待どおりの挙動)
- ビルド時と実行時でフラグが食い違えば起動を中止する
- `true` / `1` などの表記揺れを吸収し、不正値はビルドを失敗させる
- **未指定時の既定値が off であること**

`test/selftest-overlay.sh` では Deployment Overlays を検証済み (63 項目 all pass):

- 既定は off (symlink / overlay とも何もしない)
- `deployment browse-content` でアーカイブ内の実パスを特定する
- **複数の WAR に入っている同名ファイルを全部オーバレイする**
- 対象ファイルを持たないデプロイメントには触らない
- オーバレイ元として EFS 上の実体が使われる
- 2 回目以降は `add` ではなく `upload` + `link` + `redeploy-affected` (冪等)
- `match=path` / `browse=off` / linkmap 4 列目明示 の各モード
- dry-run / status / browse / remove
- CLI 失敗・起動タイムアウト・対象ゼロ・不正値で非0終了
- entrypoint が起動コマンドを `exec` しつつ overlay を適用する

---

## 追加検討: 実体をログツリー配下に置く場合

`/mnt/logs/front/logs/intra-web/tmp/date_config.properties` を実体にする案の
問題点・実現可能性・実装は [docs/alt-per-service-path.md](docs/alt-per-service-path.md) を参照。

結論だけ書くと:

- **技術的には完全に実現可能**。変更は `linkmap.conf` の 1 行だけ
- ただし `/mnt/logs/**` に対するログ削除バッチの巻き添えで
  設定ファイルが消えるリスクが最大の問題 (緩和策は同ドキュメント §5)
- 「`/mnt/logs` 直下を汚したくない」だけが理由なら、
  イメージのリンク先はメイン実装のままにして、
  **EFS 上で `/mnt/logs/tmp/date_config.properties` 自体を symlink にする**折衷案を推奨。
  イメージ再ビルドなしで実体の置き場所を変えられる
