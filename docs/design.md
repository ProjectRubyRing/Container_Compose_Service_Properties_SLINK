# 設計: readonlyRootFilesystem 下での共有プロパティファイル

## 1. 課題の本質

| 要件 | 制約 |
|---|---|
| `/webapp/webapp9mXX/servlets/jp/co/sample/base/date_config.properties` を symlink にしたい | `/webapp` は `readonlyRootFilesystem=true` の対象 → **実行時に作成不可** |
| 実体は EFS に置き、EC2 から編集したい | EFS `/mnt/logs` は書き込み可 (uid 6301 / gid 6302) |
| 4 サービス × front/back = 8 コンテナで **1 ファイル共有** | 8 コンテナが同時起動しうる → 初回生成に競合 |
| ECS タスク再起動でも内容維持 | 起動のたびに上書きしてはいけない |
| 今後ファイルが増えても対応可能 | ハードコードしない仕組みが必要 |

**結論: symlink はイメージビルド時に焼き込み、実体の生成だけを実行時に行う。**

---

## 2. なぜ「ビルド時に焼き込む」以外に選択肢がないのか

検討した代替案と却下理由:

| 案 | 判定 | 理由 |
|---|---|---|
| entrypoint で `ln -s` する | ✗ | `/webapp` が read-only。`EROFS` で失敗する |
| `linuxParameters.tmpfs` を `/webapp/.../base` に被せる | ✗ | **Fargate は `tmpfs` 非対応** (EC2 起動タイプ専用) |
| 空ボリューム (bind mount) を `/webapp/.../base` に被せる | ✗ | ECS の空ボリュームはイメージの中身をコピーしない。同ディレクトリの他ファイルが全てマスクされる |
| EFS を `/webapp/.../base` に直接マウント | △ | 技術的には可能だが、そのディレクトリの全ファイルを EFS 側で保守する必要があり、アプリ資材とインフラの責務が混ざる。リリースのたびに EFS 側の同期漏れ事故が起きる |
| `readonlyRootFilesystem` を `false` にする | ✗ | セキュリティ要件の後退。今回の前提条件そのものを崩す |
| Init コンテナ (`dependsOn: SUCCESS`) で作る | ✗ | 別コンテナのルートファイルシステムには書き込めない。共有できるのはボリュームだけ |

→ **イメージビルド時の `ln -s` が唯一の現実解**。
symlink はアクセス時に遅延解決されるため、ビルド時点で `/mnt/logs` が存在せず
dangling でも、実行時にマウントされていれば正しく解決される。

---

## 3. 全体構成

```
【ビルド時 (root)】  ※ SHARED_CONF_SYMLINK=on の場合。off は §9 参照
  build-shared-links.sh
    ├─ 元ファイルを /opt/app/shared-conf/defaults/... に初期値として退避
    └─ /webapp/webapp9mXX/servlets/jp/co/sample/base/date_config.properties
         を  /mnt/logs/tmp/date_config.properties  への symlink に置換
                                             ↑ この時点では dangling (正常)

【実行時 (appuser 6301:6302)】
  shared-conf-entrypoint.sh
    ├─ /mnt/logs のマウント待ち
    ├─ /mnt/logs/tmp/date_config.properties が「無ければ」初期値から生成
    │    → link(2) を使うのでアトミック。8 コンテナ同時起動でも1ファイル
    │    → 「有れば絶対に触らない」= タスク再起動で内容維持
    ├─ 全 symlink が解決できるか検証 (できなければ起動中止)
    └─ exec "$@"  → JBoss EAP 起動

【EC2 (RHEL 9.8)】
  init-shared-conf.sh   : /mnt/logs/tmp を 6301:6302 / 2775 で作成
  edit-shared-conf.sh   : 所有者・permission を保ったまま原子的に更新
```

### 実行時の解決パス

```
front:  /webapp/webapp9mf02/servlets/jp/co/sample/base/date_config.properties
back :  /webapp/webapp9mb02/servlets/jp/co/sample/base/date_config.properties
                    ↓ symlink (イメージに焼き込み済み)
        /mnt/logs/tmp/date_config.properties      ← 実体は EFS 上に1つだけ
                    ↑
        EC2:/mnt/logs/tmp/date_config.properties  ← ここを編集する
```

---

## 4. 複数ファイルへの拡張

`image/linkmap.conf` に 1 行足すだけ。ビルド時スクリプトと実行時スクリプトが
**同じマニフェストを読む**ので、片方だけ更新し忘れる事故が起きない。

```
${APP_ROOT}/servlets/jp/co/sample/base/holiday_config.properties  ${SHARED_CONF_DIR}/holiday_config.properties  -
```

第3列 (初期値の場所) を `-` にすると
`${DEFAULTS_DIR}/<APP_ROOT からの相対パス>` に自動決定されるため、
別ディレクトリの同名ファイルを追加しても衝突しない。

---

## 5. 同時起動の競合対策

8 コンテナが同時に「実体が無い」と判断した場合でも壊れないよう、
一時ファイルを作ってから `link(2)` で公開する。

```sh
cp "$default" "$dir/.seed.$$.<epoch>.tmp"
ln "$dir/.seed.$$.<epoch>.tmp" "$target"   # 既に存在すれば EEXIST で失敗 (アトミック)
rm -f "$dir/.seed.$$.<epoch>.tmp"
```

`link(2)` は NFSv4 (EFS) 上でもアトミックであることが保証されている。
`[ -e ] && cp` のような check-then-act だと競合で内容が混ざる可能性がある。

`test/selftest.sh` の項目 6 で 8 並列起動を実際に再現して検証済み。

---

## 6. 運用上の注意点 (重要)

### 6.1 編集しても即座には反映されない可能性が高い

symlink 自体はアクセスのたびに解決されるので、
**EC2 で編集した内容はコンテナのファイルシステムからは即座に見える**。
しかし多くの Java アプリは `Properties#load` を **起動時に1回だけ**行う。

→ 反映には ECS サービスの再デプロイが必要:

```bash
for svc in intra-api inter-api sf-api intra-web; do
  aws ecs update-service --cluster <cluster> --service "$svc" --force-new-deployment
done
```

動的に反映したい場合は、アプリ側で
`File#lastModified()` を見て再読込するか、定期リロードを実装する必要がある。
(その場合は次項の NFS 属性キャッシュに注意)

### 6.2 EFS (NFS) の属性キャッシュ

EFS は NFSv4。`lastModified` / ファイルサイズ等の属性は
クライアント側に数秒〜数十秒キャッシュされる。
アプリで定期リロードを実装する場合、EC2 での編集が全コンテナに揃うまで
最大で属性キャッシュ分の遅延が出る。整合性が要るなら再デプロイ方式にすること。

### 6.3 ファイル読み込み経路の確認 (要検証)

| 読み込み方法 | symlink の追従 |
|---|---|
| `new File("/webapp/.../date_config.properties")` / `Files.newInputStream` | ○ OS が解決するので確実 |
| `Class#getResourceAsStream` (JBoss VFS 経由 / 展開済みディレクトリ) | ○ 通常のファイル IO で解決される |
| `Class#getResourceAsStream` (WAR/EAR アーカイブを VFS が `jboss.server.temp.dir` に展開するデプロイ形態) | ✗ **展開時点のコピー**を読むため symlink の意味がなくなる |
| Undertow が HTTP 静的リソースとして配信 | △ リソースマネージャの正規化チェックにかかる可能性あり (そもそも .properties を配信すべきではない) |

`/webapp/webapp9mXX` は展開済みディレクトリとして扱われている構成に見えるため
1つ目/2つ目に該当するはずだが、**適用前に §7 の手順で実測すること**。
3つ目に該当した場合は、アプリ側を絶対パス読み込みに変えるか、
`jboss-deployment-structure.xml` で外部ディレクトリを resource-root に加える対応が必要。

### 6.4 ECS Exec と readonlyRootFilesystem

`readonlyRootFilesystem=true` のままだと SSM Agent が
`/var/lib/amazon` `/var/log/amazon` に書けず ECS Exec が失敗する。
検証のために空ボリュームをマウントしておくこと
(`taskdef/taskdef-intra-web.example.json` に含めてある)。

### 6.5 `/mnt/logs/tmp` という名前について

`tmp` は「消してよいもの」に見えるため、
ログ掃除バッチや運用手順で誤って削除されるリスクがある。
**`/mnt/logs/conf` などの名前を強く推奨する。**

ただし symlink のリンク先は**イメージに焼き込まれ、実行時の環境変数では変更できない**。
後から変えるにはイメージ再ビルドが必要なので、名前は最初に決め切ること。

どうしても後から変えられるようにしたい場合は、EFS 側に中間 symlink を置く:

```bash
# イメージのリンク先は /mnt/logs/tmp/date_config.properties のまま固定にしておき、
# EFS 上でその名前自体を symlink にする
sudo mkdir -p /mnt/logs/conf
sudo mv /mnt/logs/tmp/date_config.properties /mnt/logs/conf/
sudo ln -sfn /mnt/logs/conf/date_config.properties /mnt/logs/tmp/date_config.properties
sudo chown -h 6301:6302 /mnt/logs/tmp/date_config.properties
```

これで実体の置き場所を EC2 側から自由に付け替えられる (イメージ再ビルド不要)。

---

## 7. 適用前の検証手順

```bash
# (1) タスク定義が共有可能な状態か (front/back の rootDirectory 一致確認)
./taskdef/verify-taskdef.sh intra-api inter-api sf-api intra-web

# (2) 実装のロジック検証 (実 EFS 不要)
bash test/selftest.sh

# (3) EC2 側の初期構築
sudo ./ec2/init-shared-conf.sh

# (4) イメージをビルドして 1 サービスだけ先行デプロイ (intra-web 推奨)

# (5) コンテナ内で実測
aws ecs execute-command --cluster <cluster> --task <task-id> --container front \
  --interactive --command "/bin/sh"

  ls -l /webapp/webapp9mf02/servlets/jp/co/sample/base/date_config.properties
  #  -> ... -> /mnt/logs/tmp/date_config.properties
  readlink -f /webapp/webapp9mf02/servlets/jp/co/sample/base/date_config.properties
  cat /webapp/webapp9mf02/servlets/jp/co/sample/base/date_config.properties
  id    # uid=6301(appuser) gid=6302(appgroup)

# (6) EC2 で編集 -> コンテナ内で cat して反映を確認 (§6.3 の実測)
sudo ./ec2/edit-shared-conf.sh --set date.format=yyyy-MM-dd /mnt/logs/tmp/date_config.properties

# (7) アプリの動作としても反映されるか確認 (再デプロイ要否の判断 = §6.1)

# (8) 問題なければ残り 3 サービスへ展開
```

---

## 8. ロールバック

イメージの symlink 化を戻すのが確実:

1. `image/linkmap.conf` の該当行をコメントアウト
2. 再ビルド → `/webapp/.../date_config.properties` はイメージ内の実ファイルに戻る
3. デプロイ

linkmap.conf を触らず、ビルド引数だけで戻すこともできる (§9):

```bash
docker build --build-arg SHARED_CONF_SYMLINK=off ...
```

緊急時 (再ビルドが間に合わない) の暫定回避:
`/mnt/logs/tmp/date_config.properties` の内容をイメージ既定値に戻す。
symlink 自体は残るが、アプリから見える内容は元通りになる。

---

## 9. ビルドモード: symlink あり / なし (`SHARED_CONF_SYMLINK`)

同一の Dockerfile / linkmap.conf のまま、ビルド引数だけで
「共有するイメージ」と「共有しないイメージ」を作り分けられる。

```bash
docker build --build-arg SHARED_CONF_SYMLINK=on  ...   # 既定 (共有あり)
docker build --build-arg SHARED_CONF_SYMLINK=off ...   # 共有なし
```

### 9.1 処理の分岐点

| | `on` | `off` |
|---|---|---|
| `build-shared-links.sh` | 元ファイルを `defaults/` に退避 → `LINK` を `TARGET` への symlink に置換 → リンク先を検証 | **イメージを書き換えない**。`LINK` が実ファイルとして存在するかだけ検証 |
| `shared-conf-entrypoint.sh` | EFS マウント待ち → 実体をシード (`link(2)`) → リンク解決を検証 → `exec` | `LINK` が実ファイルとして読めるかだけ検証 → `exec` |
| EFS への依存 | あり。`/mnt/logs` が無ければ起動失敗 (`SHARED_CONF_STRICT=on`) | **なし**。EFS に一切アクセスしない |
| 設定の変更 | EC2 で編集 → 再デプロイ | イメージ再ビルド |

`off` でも entrypoint と linkmap はイメージに入ったままなので、
**イメージの構成 (COPY / ENTRYPOINT / CMD) は両モードで完全に同じ**。
差分は「`/webapp/.../*.properties` が symlink か実ファイルか」だけになる。

### 9.2 なぜ off でも entrypoint を残すか

Dockerfile を 1 本に保つため。`off` のときに ENTRYPOINT まで分岐させると、
CMD の書き分けや USER 指定の重複が発生し、両モードの差分が広がって
「off でビルドしたイメージだけ起動コマンドが古い」という事故が起きやすい。

`off` の entrypoint は EFS に触れず、対象ファイルの存在確認だけを行って
即座に `exec` するため、起動時間への影響は無視できる。

### 9.3 ビルド時と実行時で値が食い違った場合

`SHARED_CONF_SYMLINK` の値は `ARG` から `ENV` に固定され、
ビルド時 (`build-shared-links.sh`) と実行時 (`shared-conf-entrypoint.sh`) の
両方が同じ値を読む。タスク定義の `environment` で上書きすると
イメージの中身と食い違うため、entrypoint が検出して起動を中止する。

| イメージ | 実行時の値 | 挙動 |
|---|---|---|
| `on` で焼いた | `off` | `symlink になっています` → 起動中止 |
| `off` で焼いた | `on` | `シンボリックリンクではありません` → 起動中止 |

いずれも `SHARED_CONF_STRICT=off` にすれば警告のみで続行するが、
**アプリが意図しない設定ファイルを読むことになる**ので推奨しない。

### 9.4 想定する使いどころ

- **段階導入**: 共有が必要なサービスだけ `on` でビルドし、残りは `off` のまま。
  タスク定義もイメージ構成も変えずにサービス単位で切り替えられる
- **切り戻し**: 共有機構に問題が出たとき、`off` で再ビルドすれば
  linkmap.conf を編集せずに従来のイメージへ戻せる (§8)
- **ローカル/CI**: EFS が無い環境で動かすイメージ。`off` なら
  `/mnt/logs` が存在しなくても起動できる

### 9.5 値の表記揺れ

`--build-arg` やタスク定義からは `true` / `1` / `yes` のような値が
渡されがちなので、`sc_flag` (linkmap-lib.sh) で `on` / `off` に正規化する。
`on`/`off`, `true`/`false`, `yes`/`no`, `1`/`0`, `enable(d)`/`disable(d)` を受け付け、
**解釈できない値は黙って off 扱いにせずエラーにする** (`SHARED_CONF_SYMLINK=of`
のようなタイプミスで共有が無効化されたまま気づかない事故を防ぐため)。
この正規化は `SHARED_CONF_SEED` / `SHARED_CONF_STRICT` にも適用している。
