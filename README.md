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

---

## 中核となる制約

`readonlyRootFilesystem=true` のため `/webapp` 配下には実行時に書き込めない。
Fargate は `tmpfs` 非対応、空ボリュームは同ディレクトリの他ファイルをマスクしてしまう。

→ **シンボリックリンクはイメージビルド時に焼き込み、実体の生成だけを実行時に行う。**

symlink はアクセス時に遅延解決されるため、ビルド時点で `/mnt/logs` が無く dangling でも問題ない。
検討した代替案と却下理由は [docs/design.md](docs/design.md) の §2 を参照。

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
  selftest.sh                        メイン実装の E2E 検証 (実 EFS 不要)
  selftest-alt.sh                    ALT-A / ALT-B の検証

docs/
  design.md                          設計根拠・却下した代替案・運用上の注意
  alt-per-service-path.md            【追加検討】実体をログツリー配下に置く場合
```

---

## 導入手順

### 0. 事前チェック

```bash
# front/back が同一 EFS・同一 rootDirectory を見ているか (ここがずれると共有されない)
./taskdef/verify-taskdef.sh intra-api inter-api sf-api intra-web

# 実装ロジックの検証 (実 EFS 不要)
bash test/selftest.sh
```

### 1. EC2 側の初期構築 (1 回だけ)

```bash
sudo ./ec2/init-shared-conf.sh
# -> /mnt/logs/tmp を 6301:6302 / mode 2775 で作成
```

### 2. イメージのビルド

`image/Dockerfile.snippet` を既存 Dockerfile の **アプリ資材 COPY より後ろ**に追記する。

```bash
docker build --build-arg APP_ROOT=/webapp/webapp9mf02 -t <repo>/intra-web-front:1.0.0 .
docker build --build-arg APP_ROOT=/webapp/webapp9mb02 -t <repo>/intra-web-back:1.0.0  .
```

ビルドログに以下が出れば成功:

```
[shared-conf/build] default をイメージから退避  : /webapp/.../date_config.properties -> /opt/app/shared-conf/defaults/...
[shared-conf/build] symlink 作成               : /webapp/.../date_config.properties -> /mnt/logs/tmp/date_config.properties
[shared-conf/build] OK: 全エントリのシンボリックリンクをイメージに焼き込みました
```

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

---

## 共有するファイルを増やす

`image/linkmap.conf` に 1 行足してイメージを再ビルドするだけ。
ビルド時スクリプトと実行時スクリプトが同じマニフェストを読むので、
片方だけ直し忘れる事故が起きない。

```
${APP_ROOT}/servlets/jp/co/sample/base/holiday_config.properties  ${SHARED_CONF_DIR}/holiday_config.properties  -
```

第 3 列 (初期値の置き場所) を `-` にすると
`${DEFAULTS_DIR}/<APP_ROOT からの相対パス>` に自動決定されるため、
別ディレクトリの同名ファイルを追加しても衝突しない。

---

## 環境変数

| 変数 | 既定値 | 説明 |
|---|---|---|
| `APP_ROOT` | (必須) | `/webapp/webapp9mf02` (front) / `/webapp/webapp9mb02` (back) |
| `SHARED_CONF_DIR` | `/mnt/logs/tmp` | 実体を置くディレクトリ |
| `SHARED_CONF_MOUNT` | 自動判定 | EFS マウントポイント (起動時の待ち合わせ対象) |
| `SHARED_CONF_LINKMAP` | `/opt/app/shared-conf/linkmap.conf` | マニフェストの場所 |
| `DEFAULTS_DIR` | `/opt/app/shared-conf/defaults` | イメージ内の初期値の置き場所 |
| `SHARED_CONF_SEED` | `on` | 実体が無いとき初期値から生成するか |
| `SHARED_CONF_STRICT` | `on` | リンクを解決できないとき起動を中止するか |
| `SHARED_CONF_MODE` | `0664` | 生成する実体の permission |
| `SHARED_CONF_WAIT` | `30` | EFS マウント待ちの最大秒数 |

`SHARED_CONF_DIR` は **linkmap と一致していなければならない**
(linkmap 側の `${SHARED_CONF_DIR}` 展開に使われるため)。
Dockerfile の `ENV` で固定しておき、タスク定義では上書きしないのが安全。

---

## 動作保証の要点

`test/selftest.sh` で以下を実機同等に再現して検証済み (18 項目 all pass):

- ビルド時に symlink へ置換され、初期値がイメージ内に退避される
- EFS 未マウント時点では dangling で、マウント後に解決される
- 実体が無ければ初回起動時に生成される
- **8 コンテナ同時起動でも実体は 1 個** (`link(2)` によるアトミックな公開)
- **タスク再起動で編集内容が維持される** (既存があれば絶対に上書きしない)
- EC2 側の編集が front/back 両方から見える
- リンクが解決できない場合は起動を中止する (`SHARED_CONF_STRICT=on`)

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
