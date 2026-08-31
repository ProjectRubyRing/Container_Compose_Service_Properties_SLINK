# 【追加検討】実体を `/mnt/logs/front/logs/intra-web/tmp/date_config.properties` に置く場合

メイン実装は `/mnt/logs/tmp/date_config.properties`。
ここでは実体を既存のログツリー配下に置く場合の **問題点 / 実現可能性 / 実装** をまとめる。

まず、この案は 2 つに分かれる。混同すると評価を誤るので分けて論じる。

| | ALT-A | ALT-B |
|---|---|---|
| リンク先 | `/mnt/logs/front/logs/intra-web/tmp/date_config.properties` **固定** | `${APP_ROOT}/logs/tmp/date_config.properties` (既存 `logs` symlink 経由) |
| 実体の数 | **1 個** (全 8 コンテナが共有) | **8 個** (サービス×front/back ごと) |
| ご要望の「共通 1 ファイル」 | 満たす | 満たさない |
| イメージの種類 | 1 種 (front/back で APP_ROOT のみ差) | 1 種 (front/back で APP_ROOT のみ差) |

---

## 1. 実現可能性

**どちらも技術的には完全に実現可能。** 障壁はない。

- 同一 EFS・同一マウント (`/mnt/logs`)・同一 uid/gid (6301/6302) なので、
  権限・マウント・アクセス経路の追加設定は一切不要。
- `readonlyRootFilesystem=true` の制約も、メイン実装と同じ
  「ビルド時に symlink を焼き込む」方式でそのまま回避できる。
- コード変更は **`image/linkmap.conf` の TARGET 列 1 行だけ**。
  スクリプト本体・タスク定義・Dockerfile はいずれも無変更。

ALT-B については、既存の `${APP_ROOT}/logs` が
`/mnt/logs/<front|back>/logs/<service>` を指す symlink であることを利用できる。
**symlink → symlink → 実体の 2 段解決**は Linux が自動で行う
(`ELOOP` 上限は 40 なので 2 段は全く問題ない)。
つまり `${APP_ROOT}/logs/tmp/...` と書くだけで、
イメージ側のリンク文字列を **サービスごとに変えることなく**、
実体をサービスごと・front/back ごとに自動で振り分けられる。

---

## 2. 問題点

### ALT-A (`/mnt/logs/front/logs/intra-web/...` 固定) 固有

| # | 問題点 | 深刻度 | 説明 |
|---|---|---|---|
| A1 | **命名と実態の乖離** | 高 | `front/logs/intra-web` 配下に、back コンテナも含む全 4 サービスの共通設定が入る。パス名からは絶対に読み取れない。運用担当者が引き継ぎで必ず混乱する |
| A2 | **サービス廃止・再作成の巻き添え** | 高 | intra-web を廃止/リネーム/ディレクトリ再作成する運用が発生した瞬間、他 3 サービス全部が停止する (STRICT=on なら起動失敗) |
| A3 | **front/back の分離が崩れる** | 中 | back コンテナが `/mnt/logs/front/...` を読む経路ができる。ログツリーの front/back 分離という設計意図に反する |

### ALT-A / ALT-B 共通 (ログツリー配下に置くこと自体の問題)

| # | 問題点 | 深刻度 | 説明 |
|---|---|---|---|
| C1 | **ログ掃除バッチの巻き添え削除** | **最高** | `/mnt/logs/**` に対する `find -mtime +N -delete` や logrotate の対象になりやすい。しかも `tmp` という名前は真っ先に削除候補にされる。設定ファイルが消えると全サービスが起動不能 (STRICT=on) または既定値で起動 (SEED=on) してしまう |
| C2 | **ログ収集エージェントへの混入** | 中 | fluent-bit / CloudWatch Agent が `/mnt/logs/**` を tail する設定だと、`.properties` をログとして収集し続ける。ノイズとコスト増 |
| C3 | **ログ容量監視の誤検知** | 低 | サービス別のログ使用量メトリクスに設定ファイル分が混ざる |
| C4 | **アプリからの誤検出** | 中 | アプリが `${APP_ROOT}/logs` 配下を再帰走査 (ログのアーカイブ・ローテート・一覧表示) する実装だと、設定ファイルを巻き込む |
| C5 | **編集オペレーションの危険度上昇** | 中 | パスが深く、`front/back` と 4 サービス名の組み合わせがあるため、別サービスのファイルを誤編集しやすい |

### ALT-B 固有

| # | 問題点 | 深刻度 | 説明 |
|---|---|---|---|
| B1 | **「共通 1 ファイル」要件を満たさない** | — | 実体が 8 個になるため、1 箇所直せば全部反映という運用ができない。8 箇所すべてを更新するスクリプトが別途必要 (下記に用意) |
| B2 | 更新漏れによる設定不整合 | 中 | 8 個のうち一部だけ古いまま、という状態が起こりうる |

---

## 3. 判定

- **ご要望どおり「全サービス共通 1 ファイル」を優先するなら、メイン実装 (`/mnt/logs/tmp/`) が明確に優位。**
  ALT-A は同じ結果を、A1〜A3 と C1〜C5 のリスクを背負って実現するだけになる。
- ただし「`/mnt/logs` 直下を汚したくない」「既存のツリー構造に収めたい」という
  組織的な理由があるなら、**C1 (ログ掃除の巻き添え) さえ潰せば ALT-A は実用に耐える。**
  → §5 の緩和策を必ずセットで入れること。
- **サービスごとに設定値を変えたくなる見込みがあるなら ALT-B が良い。**
  イメージを増やさずにサービス別設定が実現できるのは ALT-B だけ。

### 折衷案 (推奨)

イメージ側のリンク先は **メイン実装のまま** (`/mnt/logs/tmp/date_config.properties`) にしておき、
EFS 上で `/mnt/logs/tmp/date_config.properties` 自体を symlink にして
好きな場所を指す。**イメージ再ビルドなしで実体の置き場所を変えられる。**

```bash
sudo mkdir -p /mnt/logs/front/logs/intra-web/tmp
sudo mv /mnt/logs/tmp/date_config.properties /mnt/logs/front/logs/intra-web/tmp/
sudo ln -sfn /mnt/logs/front/logs/intra-web/tmp/date_config.properties \
             /mnt/logs/tmp/date_config.properties
sudo chown -h 6301:6302 /mnt/logs/tmp/date_config.properties
```

これなら「置き場所の決定」を後戻り可能な運用判断に変えられる。

---

## 4. 実装

### 4.1 ALT-A: 全コンテナが 1 ファイルを共有 (共通要件を満たす)

`image/linkmap.conf` を差し替えるだけ。他は一切変更なし。

```
# LINK                                                          TARGET
${APP_ROOT}/servlets/jp/co/sample/base/date_config.properties   /mnt/logs/front/logs/intra-web/tmp/date_config.properties   -
```

EC2 側の初期構築:

```bash
sudo ./ec2/init-shared-conf.sh --dir /mnt/logs/front/logs/intra-web/tmp
```

タスク定義の environment (entrypoint のマウント待ち対象を明示):

```json
{ "name": "SHARED_CONF_DIR",   "value": "/mnt/logs/front/logs/intra-web/tmp" },
{ "name": "SHARED_CONF_MOUNT", "value": "/mnt/logs" }
```

> `SHARED_CONF_MOUNT` は省略しても、先頭 2 階層から `/mnt/logs` と自動判定される。

編集:

```bash
sudo ./ec2/edit-shared-conf.sh --set date.format=yyyy-MM-dd \
     /mnt/logs/front/logs/intra-web/tmp/date_config.properties
```

### 4.2 ALT-B: サービス別・front/back 別 (既存 `logs` symlink を経由)

`image/linkmap.conf`:

```
# ${APP_ROOT}/logs は既存の symlink (-> /mnt/logs/<front|back>/logs/<service>)。
# これを踏み台にすることで、イメージ側のリンク文字列を変えずに
# 実体をサービスごと・ロールごとに振り分けられる。
${APP_ROOT}/servlets/jp/co/sample/base/date_config.properties   ${APP_ROOT}/logs/tmp/date_config.properties   -
```

タスク定義の environment:

```json
{ "name": "SHARED_CONF_DIR",   "value": "/webapp/webapp9mf02/logs/tmp" },
{ "name": "SHARED_CONF_MOUNT", "value": "/mnt/logs" }
```

> `SHARED_CONF_DIR` は `${APP_ROOT}` に合わせて front/back で変える。
> `SHARED_CONF_MOUNT` は **必須** (`/webapp/webapp9mf02` を EFS マウントと
> 誤判定させないため)。

EC2 側の初期構築 + 8 箇所一括更新には `ec2/init-shared-conf-per-service.sh` を用意した:

```bash
# 8 ディレクトリを作成
sudo ./ec2/init-shared-conf-per-service.sh init

# 8 ファイルへ一括反映 (B1/B2 対策)
sudo ./ec2/init-shared-conf-per-service.sh sync ./seed/date_config.properties

# 8 ファイルの差分確認
sudo ./ec2/init-shared-conf-per-service.sh diff
```

---

## 5. ALT-A / ALT-B を採用する場合に必須の緩和策

C1 (ログ掃除の巻き添え削除) は実際に起きる。以下は必須。

### 5.1 ログ削除バッチから除外

```bash
# NG: tmp ごと消える
find /mnt/logs -type f -mtime +90 -delete

# OK: tmp ディレクトリを prune
find /mnt/logs -type d -name tmp -prune -o -type f -mtime +90 -print -delete
```

### 5.2 logrotate から除外

```
/mnt/logs/*/logs/*/*.log {
    daily
    rotate 90
    missingok
    notifempty
    # tmp 配下は対象外 (glob が *.log なので既に対象外だが、明示しておく)
}
```

### 5.3 ログ収集エージェントから除外 (fluent-bit の例)

```ini
[INPUT]
    Name              tail
    Path              /mnt/logs/*/logs/*/*.log
    Exclude_Path      /mnt/logs/*/logs/*/tmp/*
```

### 5.4 ディレクトリ名を `tmp` 以外にする

最も効果的な対策。`tmp` → `conf` にするだけで誤削除リスクが大きく下がる。

```
/mnt/logs/front/logs/intra-web/conf/date_config.properties
```

### 5.5 削除検知

実体が消えた場合、`SHARED_CONF_STRICT=on` なら次回タスク起動時に
起動失敗して確実に気付ける (サイレントに既定値で動き続けるより安全)。
EC2 側に存在監視を1本入れておくとさらに良い:

```bash
test -f /mnt/logs/front/logs/intra-web/tmp/date_config.properties \
  || logger -p user.err "共有設定ファイルが消失しています"
```
