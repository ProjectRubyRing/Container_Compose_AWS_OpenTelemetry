# Container_Compose_AWS_OpenTelemetry

ECS タスク内の JBoss EAP 8.1 コンテナ (front / back) と ADOT サイドカーで、
**Aurora / Valkey / ALB / EC2 / SQS / Lambda / 外部 SLB を含む全通信を
AWS X-Ray に分かりやすく可視化する**ための実装一式。

ローカルは Compose + Jaeger、本番は ECS + X-Ray。
**同じイメージ・同じ加工処理で送信先だけを差し替える**設計になっている。

---

## 何が入っているか

| | |
|---|---|
| ベースコンテナ | UBI 9.8 + Red Hat build of OpenJDK 21 + JBoss EAP 8.1 (jboss-cli.sh 構成) + ADOT Java Agent |
| front / back | ベースを継承し、WAR (archive 方式) と固有 CLI だけを足す |
| 共通シェル | `jvm-env.sh` → `otel-env.sh`。JVM と OpenTelemetry の環境変数を 1 か所で組み立てる (JVM オプションの渡し方は 2 通り) |
| ADOT サイドカー | Collector 設定 2 本 (X-Ray 用 / Jaeger 用)。差分は `★XRAY-DIFF` コメントのみ |
| ローカル環境 | Compose 一式。ALB / 帳票 EC2 / EC2 バッチ / Lambda / SQS のスタブ込み |
| ECS | タスク定義テンプレートと 4 サービスぶんの生成スクリプト |

---

## ディレクトリ

```
base/                     ★ front/back 共通のベースコンテナ
  Containerfile             UBI9.8 + OpenJDK21 + EAP8.1 + ADOT Agent
  bin/
    entrypoint.sh           起動処理 (共通)
    apply-cli.sh            ★ 起動時に embed-server + batch ～ run-batch で CLI を適用
    jvm-env.sh              ★ JVM 環境変数の共通シェル (JAVA_OPTS_APPEND 版 / 既定)
    jvm-env-javaopts.sh     ★ 同上 (JAVA_OPTS 版。既定値を全部自前で持つ)
    otel-env.sh             ★ OpenTelemetry 環境変数の共通シェル (命名規約の実体)
    healthcheck.sh
  cli/
    00-server-common.cli    アクセスログ (trace 相関) / proxy-address-forwarding
    10-remove-mp-opentelemetry.cli  ★ EAP 内蔵 OTel を外して二重計装を防ぐ
    20-datasource-aurora.cli        Aurora Serverless v2 (MySQL 8.4)
    30-elytron-https-remove.cli     ★ 未使用の既定 HTTPS/キーストアを削除 (WFLYELY00023/01084 の根本回避)
    31-logging-suppress-known-warnings.cli
                                    ★ 既知 WARN を filter-spec で直接抑制
  build/
    standalone.conf.append  JAVA_OPTS_APPEND フック

front/  back/             各ロールの Containerfile と固有 CLI (適用は起動時)
sample-app/               全経路を叩く検証用 WAR (実 WAR に差し替え可)

otel/
  collector-xray.yaml     ★ 本番 ECS 用 (awsxray)
  collector-compose.yaml  ★ ローカル用 (Jaeger)   ← 差分は ★XRAY-DIFF のみ

sim/                      ローカル専用スタブ (ALB / Lambda / 帳票EC2 / バッチ)
ecs/                      タスク定義テンプレート
scripts/                  build / up / down / smoke-trace / gen-taskdefs / drift check
docs/
  naming-convention.md       ★ 命名規約と X-Ray での検索方法
  xray-vs-jaeger.md          ★ Compose と X-Ray の差分・注意点
  trace-paths.md             ★ 7 経路それぞれの伝播の仕組み
  peer-service-resolution.md ★ 下流ノード名の多段階判定 (ドメイン/ポート/AWS)
  request-attributes.md      ★ ヘッダ・クエリ・パラメータ・ボディの載せ方と限界
  alb-tracing.md             ★ ALB を挟んだ EC2 通信の見え方と、その先まで繋ぐ方法
```

---

## 設計の要点

### 1. 名前は人が書かず、4 つの入力から導出する

X-Ray のサービスマップは **`service.name` をそのままノード名にする**。
ここが揺れると同じコンテナが 2 ノードに分裂し、しかも間違って見えないので気づけない。

タスク定義が与えるのは `APP_SERVICE` / `APP_ROLE` / `APP_ENV` / `APP_NAMESPACE` の 4 つだけ。
`base/bin/otel-env.sh` がここから全部を導出する。

```
service.name = ${APP_SERVICE}-${APP_ROLE}

  intra-api + front -> intra-api-front      inter-api + front -> inter-api-front
  intra-api + back  -> intra-api-back       inter-api + back  -> inter-api-back
  intra-web + front -> intra-web-front      sf-api    + front -> sf-api-front
  intra-web + back  -> intra-web-back       sf-api    + back  -> sf-api-back
```

規約外の値が来たら **コンテナを起動させない**。壊れたトレースが X-Ray に
出てから気づくより、起動しない方が圧倒的に安い。

→ 詳細: [`docs/naming-convention.md`](docs/naming-convention.md)

### 2. 計装していない相手のノード名は多段階判定で決まる

Aurora / Valkey / ALB / 帳票 EC2 / 外部 SLB は計装できない。既定ではマップに
`aurora-xxx.cluster-abc.ap-northeast-1.rds.amazonaws.com` のような FQDN が並び、
長くて読めないうえ環境ごとに文字列が違うので同じ相手が別ノードに割れる。

`peer.service` を付ければノード名を完全に制御できる (X-Ray の
`awsxray` exporter がノード名を決める際、FQDN より優先して見る)。
その `peer.service` を **5 段の判定**で決める。上の段で決まったら打ち切る。

| 段 | 何を見るか | 決めるのは |
|---|---|---|
| 0 `explicit` | `APP_PEER_SERVICE_MAPPING` に運用が書いた対応 | アプリ |
| 1 `role` | `DB_HOST` などの**変数名** (用途が確定している) | アプリ |
| 2 `domain` | ホスト名の**部分一致** (`.rds.amazonaws.com` など) | アプリ + Collector |
| 3 `port` | **ポート番号** (`3306` / `6379` / `18080` など) | アプリ + Collector |
| 4 `aws` | AWS の命名規則 / AWS SDK 計装の属性 | アプリ + Collector |

段2 の部分一致は FQDN 全体を書かないので、dev/stg/prd でエンドポイントが
変わっても追随不要。段3 は **ECS のタスク内で唯一の区別手段**になる
(awsvpc では front も back も ADOT サイドカーも同じ `localhost` なので、
`localhost:18080` のようにポートまで含めないと区別できない)。

段2 以降は Collector 側 (`transform/peer-service-resolve`) にも同じ規則が
あり、アプリが決められなかったスパン (運用中に足された連携先、AWS SDK が
内部で叩く別サービス、IP 直指定) をそこで拾う。

**どの段で決まったかを残すのがこの仕組みの肝。**

```sh
docker compose logs front | grep -A 8 "peer 判定"
#   DB_HOST=aurora:3306 -> aurora-mysql (段: role)
#   10.0.3.21:6379      -> elasticache-valkey (段: port)
```

```
annotation.app_peer_src = "host"   # ★ 名前を付け損ねている相手の一覧
```

→ 詳細: [`docs/peer-service-resolution.md`](docs/peer-service-resolution.md)

### 2-2. リクエストの中身をどこまで載せられるか

| 対象 | 自動計装だけで | 属性名 |
|---|---|---|
| ヘッダ (サーバ / クライアント、req / res) | **出せる** | `http.request.header.<名前>` ほか |
| クエリ文字列 | **既定で出る** | `url.query` / `url.full` |
| リクエストパラメータ (GET のクエリ + POST のフォーム) | **出せる** | `servlet.request.parameter.<名前>` |
| **ボディ (JSON / XML)** | **出せない** (機能が存在しない) | — |

ヘッダは許可リスト方式で、認証情報を含むものは
`APP_CAPTURE_HEADERS_DENY` がアプリ側で弾き、Collector 側でも捨てる。
クエリ文字列は設定不要で載ってしまうので、逆に
`transform/redact-sensitive` が `token=REDACTED` のように値を伏せる
(エージェント側の伏せ字機能は OpenTelemetry Java 2.14.0 以降のもので、
本構成が固定している ADOT 2.11 系には無い。**いま効いているのは
Collector 側**)。

→ 詳細と代替手段: [`docs/request-attributes.md`](docs/request-attributes.md)

### 2-3. ALB を挟んだ EC2 通信

**ALB は X-Ray にセグメントを送らない。** API Gateway と違い、ALB の
ノードがマップに自動で生えることは無い。出るのはこちらのクライアント
スパンが作る推定ノード 1 個だけで、ALB とターゲットの内訳は
X-Ray だけでは分離できない。

自動計装の範囲で取れるようにしてあるもの:

| annotation | 何が分かるか |
|---|---|
| `app_via=alb` | ALB (プロキシ) を通っているか |
| `app_upstream` | ALB の裏で実際に応答したサーバ (ターゲットが名乗った場合) |
| `client_ip` | ALB の手前の実クライアント IP (`X-Forwarded-For` の先頭) |
| `client_proto` | 利用者側が https だったか (ALB で TLS 終端するため中は http) |
| `alb_trace_id` | ALB アクセスログ (`target_processing_time`) との結合キー |

**ALB の先の EC2 まで繋ぐことは可能**で、EC2 側の JVM に同じ ADOT
エージェントを入れるだけでよい (アプリ改修は不要)。その場合は
EC2 の `OTEL_SERVICE_NAME` を `peer.service` と同じ文字列にすること。
違うと同じ相手が 2 ノードに割れる。

→ 詳細: [`docs/alb-tracing.md`](docs/alb-tracing.md)

### 3. X-Ray で「検索できる」形にする

リソース属性は X-Ray では metadata に入り**フィルタ式で検索できない**。
Collector の `transform/xray-annotations` がスパン属性へ写し、
`awsxray.indexed_attributes` で annotation に昇格させている。

```
annotation.app_service = "sf-api"  AND annotation.app_role = "back"
annotation.app_caller  = "batch-ec2"      # EC2 バッチ由来だけ
annotation.app_peer    = "aurora-mysql"   # Aurora を呼んでいるスパンだけ
```

同じ transform をローカルの Collector でも通しているので、
Jaeger の Tags 欄でも `app_caller=batch-ec2` で同じ結果が得られる。

`indexed_attributes` に並べるのは **transform 後のフラットなスパン属性名**
(`app_ns` / `app_env` / `app_role` / `app_peer_src` / `app_via` /
`app_upstream` / `client_ip` / `alb_trace_id` / `ecs_cluster` /
`ecs_service` / `ecs_task_family` など) であって、`service.namespace` や `aws.ecs.task.family` の
ようなリソース属性名ではない。書き間違えてもエラーにならず
「annotation が付かないだけ」なので、`./scripts/smoke-trace.sh` の後に
Jaeger の Tags で 1 つずつ引けることを確認する。
→ 対応表と確認手順: [`docs/xray-vs-jaeger.md`](docs/xray-vs-jaeger.md#3-リソース属性は-x-ray-では検索できない)

### 4. ADOT 版エージェントを使う (標準エージェントでは動かない)

X-Ray はトレース ID の先頭 4 バイトを epoch 秒として解釈し、
外れた ID を捨てる。標準の `opentelemetry-javaagent.jar` は完全ランダムな
128bit を採番するため大半が捨てられる。

しかも **Jaeger はランダム ID を受け付けるのでローカルでは完璧に動いて見える**。
本番に出した瞬間だけ何も出なくなる。

`aws-opentelemetry-agent.jar` は X-Ray 互換の ID ジェネレータを既定で持つ。
X-Ray 形式の ID は正当な 128bit なので Jaeger でも問題ない = **両対応になる**。

### 5. Collector 設定 2 本のずれを機械で検出する

`otel/collector-xray.yaml` と `otel/collector-compose.yaml` は別ファイルなので、
片方だけ直すと静かにずれる。ずれると「ローカルでは `app_caller` があるのに
X-Ray には無い」という本番でしか出ない不具合になる。

```sh
./scripts/check-collector-drift.sh
```

共通であるべきブロック (`filter` / `transform` / `batch`) を比較する。
CI に入れるか、Collector 設定を触ったら必ず実行する。

---

## 使い方 (ローカル)

```sh
cp .env.example .env

# ビルド (EAP 8.1 の zip が vendor/ にある場合)
./scripts/build.sh
# zip が無い環境 (WildFly 35 で代替。CLI/entrypoint/OTel 設定はそのまま通る)
./scripts/build.sh --wildfly

# 起動
./scripts/up.sh
# EC2 バッチスタブも動かす場合
./scripts/up.sh --batch

# 全通信経路を叩いてトレースを起こす
./scripts/smoke-trace.sh

# 確認
#   Jaeger UI : http://localhost:16686
#   front     : http://localhost:8080/front/api/health
#   ALB (sim) : http://localhost:8081/front/api/health
```

Jaeger で確認すること:

- Service に `intra-api-front` / `intra-api-back` が出ている
- 1 トレースに mysql / redis / http / sqs のスパンが並んでいる
- Tags に `app_service` / `app_role` / `app_caller` / `app_peer` が入っている

---

## 使い方 (ECS / X-Ray)

```sh
# 1. タスク定義を 4 サービスぶん生成
./scripts/gen-taskdefs.sh prd shopdemo

# 2. Collector 設定を Secrets Manager へ
aws secretsmanager create-secret \
  --name /adot/collector-config/prd \
  --secret-string file://otel/collector-xray.yaml

# 3. 生成された JSON の <...> を置換して登録
aws ecs register-task-definition --cli-input-json file://ecs/generated/intra-api-prd.json
```

必須の前提:

- **タスクロール** (executionRole ではない) に `AWSXRayDaemonWriteAccess`
  → `GetSampling*` が無いと `OTEL_TRACES_SAMPLER=xray` が動かず全量送信に
  フォールバックし、料金が跳ねる形で表面化する
- **ECS サービス名 = `APP_SERVICE`** にすること

---

## ローカルで再現している通信経路

| # | 経路 | ローカルでの再現 |
|---|---|---|
| 1 | front → back (タスク内) | `back:18080` |
| 2 | front/back → Aurora Serverless v2 (MySQL 8.4) | `mysql:8.4` |
| 3 | front/back → ElastiCache for Valkey | `valkey/valkey:8` |
| 4 | front/back → ALB → 帳票 EC2 | ALB スタブ + 計装しない HTTP スタブ |
| 5 | EC2 バッチ → ALB → コンテナ | バッチスタブ (ALB が `X-Amzn-Trace-Id` を採番) |
| 6 | front → SQS → Lambda → ALB → back | LocalStack SQS + Lambda スタブ |
| 7 | front/back → 外部 SLB → VPC 外 | 計装しない HTTP スタブ |

**経路 5 のために ALB のスタブを自作している。**
計装されていない呼び出し元が入口の経路は、ALB が `X-Amzn-Trace-Id` を
採番することで初めて 1 本のトレースになる。素の nginx では再現できない。

→ 各経路の伝播の仕組み: [`docs/trace-paths.md`](docs/trace-paths.md)

---

## JBoss EAP 固有の注意点

| 項目 | 内容 |
|---|---|
| `JAVA_OPTS` を直接渡すなら既定値を全部自前で持つ | standalone.conf は `JAVA_OPTS` が未設定のときしか既定値を組み立てない。既定 (`JVM_OPTS_MODE=append`) は `JAVA_OPTS_APPEND` を使い、直接渡す場合は `JVM_OPTS_MODE=full` (`jvm-env-javaopts.sh`) で消える既定値を明示する |
| `JAVA_TOOL_OPTIONS` を使わない | `jboss-cli.sh` まで計装され、CLI が遅くなり無意味なスパンが出る。`-javaagent` は `JAVA_OPTS_APPEND` / `JAVA_OPTS` へ |
| `JBOSS_MODULES_SYSTEM_PKGS` | `io.opentelemetry.javaagent` を追加必須。無いとクラスローダ隔離で `NoClassDefFoundError` |
| EAP 内蔵 opentelemetry サブシステム | Java Agent と二重計装になりスパンが 2 本出る。`10-remove-mp-opentelemetry.cli` で外す |
| `OTEL_SERVICE_NAME` を必ず明示 | エージェントはデプロイ名から service.name を推測する。明示しないと 4 サービスぶんの front が全部 `front` という 1 ノードに潰れる |
| トレース関連 WARN は `filter-spec` では止まらない | エージェントのログは `OTEL_JAVAAGENT_LOGGING=simple`（既定）では JBoss の logging サブシステムを通らず stderr へ直接書かれる。抑制は JVM のシステムプロパティ＝`OTEL_TRACE_WARN_SUPPRESS`（グループ）で行う |
| CLI はコンテナ起動時に適用 | イメージが持つのは素の `standalone.xml` と `.cli` だけ。`entrypoint.sh` が作業領域 (`/run/eap`) の複製へ適用するので、構成の変更に再ビルドが要らない。代償は起動が `embed-server` 2 回ぶん遅くなること |
| `standalone_xml_history` は適用直後に消す | 残っていると続く `standalone.sh` の本ブートが `current` の rename を試みる。この rename はファイルシステム依存で、履歴がイメージ (overlayfs) 側に在ると Compose では警告 (WFLYCTL0414) / ECS では起動失敗 (WFLYCTL0082) という環境差になる。作業領域に作って即消せば「履歴の無い初回ブート」になり発生しない |
| CLI は `batch` ～ `run-batch` で適用 | 1 個の composite になるので「全部入るか、1 つも入らないか」になる。バッチ内では `if` / `echo` が使えないため、`apply-cli.sh` が probe パスでガードを先に解決してから流し込む (下記) |
| CLI の JVM に `JAVA_OPTS` を渡さない | 起動時に走る以上、アプリ用の `JAVA_OPTS` (`full` では `-javaagent` を含む) を継ぐと `jboss-cli.sh` まで計装される。`apply-cli.sh` が CLI 用の `JAVA_OPTS` を組み立て直し、`JAVA_TOOL_OPTIONS` も落とす |
| Valkey は Jedis / Lettuce で | `valkey-java` はエージェントの計装対象外。使うとキャッシュアクセスのスパンが一切出ない |
| コンテキストルートを分ける | front=`/front` / back=`/back`。実 ALB はパスを書き換えず転送するため、両方 `/app` だとパスベースのルールで振り分けられない |

---

## CLI の適用方式 (起動時 / embed-server + batch)

`base/bin/apply-cli.sh` が `.cli` を集めて、**次の形のスクリプトを 1 本生成して流す**。

```
embed-server --server-config=standalone.xml --std-out=echo
batch
    <.cli の操作をすべてここに並べる>
run-batch
stop-embedded-server
```

`batch` ～ `run-batch` は 1 個の composite 操作になるので、

- 全操作が成功したときだけ `standalone.xml` へ書かれる (原子性)
- 途中で失敗したら全部ロールバックされ、**中途半端な設定のサーバが起動しない**
- 書き込みが 1 回にまとまる

つまり「CLI が通った = 設定は全部入った」が保証される。失敗すれば `entrypoint.sh` が
そこで停止し、コンテナは起動してこない。

### いつ走るのか

コンテナ起動のたび、`entrypoint.sh` の 5. で走る。

```
1. root 起動時のみ権限降格
2. 作業領域 /run/eap を用意
3. configuration をイメージ内シードから複製
4. WAR (archive) の実体を検証
5. ★ CLI を適用 (apply-cli.sh)        ← ここ
6. jvm-env*.sh -> otel-env.sh
7. ADOT サイドカーの待ち合わせ (任意)
8. standalone.sh を exec
```

イメージに焼かれているのは **EAP 既定の素の `standalone.xml` (シード) と `.cli` だけ**で、
設定は入っていない。3. で作業領域へ複製したものに対して 5. が適用する
(`EAP_CONFIG_SEED=always` が既定なので、毎起動シードからやり直す)。

| | |
|---|---|
| 適用順 | `0*` → `1*` → `2*` → (`30*`) → `31*` → ロール固有 (`5*`=front / `6*`=back) |
| `30*` の有無 | `EAP_HTTPS_MODE` で決まる (`remove`=適用 / `keystore`・`keep`=適用しない) |
| ロール固有 | `EAP_CLI_ROLE_PATTERNS` (front/back の Containerfile が `ENV` で設定) |
| 丸ごと差し替え | `EAP_CLI_PATTERNS` に空白区切りで指定すると上の導出を置き換える |
| 止める | `EAP_CLI_ENABLED=false` (シードのまま起動。切り分け用) |
| ログ | `EAP_CLI_STDOUT=discard` で適用時の `embed-server` ブートログを捨てる |

**ビルド時に適用しない理由**は、同じイメージのまま起動時の環境変数で構成を変えられること
(`EAP_HTTPS_MODE` の再ビルドが要らない)、front/back のビルドが「WAR を置くだけ」になること。
代償として、コンテナの起動が `embed-server` 2 回ぶん (数十秒) 遅くなる。
ヘルスチェックの `start_period` / `startPeriod` (120s / 180s) はこれを織り込んである。

### なぜ 2 パス構成なのか

JBoss CLI のバッチに積めるのは**操作要求だけ**で、`if` / `else` / `end-if` の制御構文と
`echo` は入れられない。一方 `.cli` 側は「すべて `if` で冪等化してある」ことが前提の作りで、
これは捨てられない (`SERVER_SOURCE=image` の社内 EAP イメージや front/back の再適用で、
リソースが元から在る/無いが変わるため)。

そこで `apply-cli.sh` は CLI 実行を 2 パスに分ける。

| | 何をするか |
|---|---|
| パス 1 (probe) | `embed-server` を起動し、`.cli` 中の `if (...) of <アドレス>:read-resource` に出てくるアドレスの**存在有無だけ**を一括で調べる。設定は変えない |
| パス 2 (apply) | パス 1 の結果で `if` を**CLI へ渡す前に**解決し、採用された枝の操作だけを `batch` ～ `run-batch` に並べて流す。`echo` は `[apply-cli]` のログ行に振り替える |

**`.cli` ファイルは今までどおり `if` / `echo` 付きで書ける。** 実際にサーバへ渡るスクリプトだけが
操作の羅列になる。生成されたスクリプトは `[apply-cli] | ...` として全文が出るので、
何が流れたかは `docker compose logs front` でそのまま確認できる。

> `embed-server` の起動が 2 回になり、そのぶんコンテナの起動が遅くなる。
> probe パスは `--std-out=discard` でブートログを捨てているぶん apply パスより速い。
> `standalone.sh` の本ブートは従来どおり 1 回のまま。

### `.cli` を書くときの制約

1. ガードは `if (outcome == success) of <アドレス>:read-resource` と `!=` の 2 形式のみ。入れ子は不可
2. ガードは batch を流す**前に**まとめて評価される。したがって「同じ run の中で先行する操作が
   作成/削除したアドレス」をガードの条件に使ってはいけない
3. `echo` は `[apply-cli]` のログ行に出る。サーバへは渡らない
4. コメント行と空行はバッチから落とされる (`.cli` が唯一の記述場所)

composite が通らない操作に当たったときの切り分け用に `--no-batch` を用意してある
(バッチで囲まずに逐次実行する)。通常の起動では使わない。

---

## JVM オプションの渡し方 (2 パターン)

JVM オプションの渡し方は 2 通り実装してあり、**起動時の環境変数
`JVM_OPTS_MODE` だけで切り替わる**。イメージは 1 つのまま、どちらでも動く。
どちらのモードでも `otel-env.sh` は共通なので、`OTEL_*` の導出と命名規約は変わらない。

| | `JVM_OPTS_MODE=append` (既定) | `JVM_OPTS_MODE=full` |
|---|---|---|
| 実体 | `base/bin/jvm-env.sh` | `base/bin/jvm-env-javaopts.sh` |
| 組み立てる変数 | `JAVA_OPTS_APPEND` | `JAVA_OPTS` |
| EAP の既定値 | standalone.conf がそのまま組み立てる | **消えるので全部自前で持つ** |
| standalone.conf | `standalone.conf.append` が `JAVA_OPTS_APPEND` を連結する | 経由しない (`JAVA_OPTS_APPEND` を空にするのでフックは no-op) |
| 向き | EAP の推奨に沿った安全側 | standalone.conf に依存したくない構成 |

### なぜ `full` では「全部自前」になるのか

standalone.conf は `JAVA_OPTS` をこうとしか組み立てない。

```sh
if [ "x$JAVA_OPTS" = "x" ]; then
    JAVA_OPTS="$JBOSS_JAVA_SIZING -Djava.net.preferIPv4Stack=true"
    JAVA_OPTS="$JAVA_OPTS -Djboss.modules.system.pkgs=$JBOSS_MODULES_SYSTEM_PKGS -Djava.awt.headless=true"
else
    echo "JAVA_OPTS already set in environment; overriding default settings with values: $JAVA_OPTS"
fi
```

外から `JAVA_OPTS` を渡した瞬間に `else` 側へ落ち、**この 4 つが 1 つも付かない**。
`jvm-env-javaopts.sh` はこれを同じ順序で再現したうえで、本構成ぶん
(`java.io.tmpdir` / DNS TTL / トラストストア) と `otel-env.sh` が積んだ
`-javaagent` を連結する。

★ 一番危険なのは **`-Djboss.modules.system.pkgs` が落ちること**。
`JBOSS_MODULES_SYSTEM_PKGS` 環境変数そのものは guard の外で既定値が入るので
「変数はある」が、`-D` へ変換しているのは guard の中だけ。ここが落ちると
JBoss Modules のクラスローダ隔離から `io.opentelemetry.javaagent` が外れ、
**起動はするのに X-Ray に何も出ない**という一番気づきにくい壊れ方をする。

### `full` で追加される環境変数

| 変数 | 既定 | 用途 |
|---|---|---|
| `JVM_OPTS_MODE` | `append` | `full` でこのモードに入る |
| `JVM_METASPACE_SIZE` / `JVM_MAX_METASPACE_SIZE` | `96M` / `256M` | EAP 既定の Metaspace 指定を踏襲する (ヒープは既存どおり割合指定) |
| `JVM_MODULAR_OPTS_MODE` | `explicit` | `--add-opens` 一式を自分で書くか (`explicit`)、`standalone.sh` に任せるか (`delegate`) |
| `JVM_MODULAR_OPTS` | 一覧を内蔵 | `--add-opens` 一式を丸ごと差し替えたい場合 |
| `JVM_PRESERVE_JAVA_OPTS` | `false` | `true` で `PRESERVE_JAVA_OPTS=true` を立て、`standalone.sh` にも `JAVA_OPTS` を触らせない |

`--add-opens` 一式だけは standalone.conf ではなく `standalone.sh`
(`bin/common.sh` の `setDefaultModularJvmOptions`) が付けているため、
`JAVA_OPTS` を渡しても実は消えない。それでも `explicit` を既定にしているのは
「JVM に渡る値はこのファイルを読めば全部わかる」を優先しているため。
一覧の最後に `--add-modules=java.se` が入るので `standalone.sh` 側は何も足さず、
二重に付くこともない。**起動直後に `IllegalAccessError` /
`InaccessibleObjectException` が出たら、まず `JVM_MODULAR_OPTS_MODE=delegate`
を試す**こと (EAP の版が一覧にない `--add-opens` を要求している可能性)。

### 確認

```bash
# 組み立て結果だけを見る (コンテナ外でも動く)
sh base/bin/jvm-env-javaopts.sh --print

# 起動ログでの確認。full のときだけ JAVA_OPTS の全文が出る
docker compose up -d
docker compose logs back | grep -E 'jvm-env|JAVA_OPTS'
```

Compose で切り替える場合:

```yaml
    environment:
      JVM_OPTS_MODE: full
```

---

## 起動時 WARN の扱い

毎起動出る既知の WARN は、**(A) 設定値を整えて発生自体を無くす**（根本回避）と
**(B) ログを直接抑制する**（フィルタ）の 2 系統を両方用意してある。
既定では A で消えるので B は保険として効いている状態になる。

| WARN | 発生源 | (A) 根本回避 — 既定 | (B) 直接抑制 |
|---|---|---|---|
| `ServiceEventConfig - OTEL_AWS_SERVICE_EVENTS_FUNCTION_INSTRUMENT_ENABLED=true but OTEL_AWS_SERVICE_EVENT_PACKAGES_INCLUDE is empty` | ADOT Java Agent | `otel-env.sh` が対象パッケージ未指定なら `..._FUNCTION_INSTRUMENT_ENABLED=false` を明示 | `-Dio.opentelemetry.javaagent.slf4j.simpleLogger.log.software.amazon.opentelemetry.javaagent.instrumentation.serviceevents=error` |
| `DbConfig - The otel.instrumentation.common.db-statement-sanitizer.enabled system property is deprecated ... Use otel.instrumentation.common.db.query-sanitization.enabled instead` | ADOT Java Agent | `otel-env.sh` が新キー `OTEL_INSTRUMENTATION_COMMON_DB_QUERY_SANITIZATION_ENABLED` だけを渡す（旧キーは渡さない／外から来ても読み替えて落とす） | `-Dio.opentelemetry.javaagent.slf4j.simpleLogger.log.io.opentelemetry.javaagent.shaded.instrumentation.api.incubator.config.internal.DbConfig=error` |
| `WFLYELY00023: KeyStore ファイル '.../application.keystore' は存在しません。空白を利用しました` | `org.wildfly.extension.elytron` | `30-elytron-https-remove.cli` が未使用の `https-listener` / `applicationSSC` / `applicationKM` / `applicationKS` / `socket-binding=https` を削除 | `31-logging-suppress-known-warnings.cli` の `filter-spec` |
| `WFLYELY01084: キーストア ... が見つかりません。初回使用時に自己署名証明書を使用して自動生成されます` | `org.wildfly.extension.elytron` | 同上 | 同上 |

### トレース関連 WARN のグループ抑制

上の 2 件のようにピンポイントで分かっているものと違い、トレースまわりの WARN は
**版が上がるたびにロガー名が変わる**。名前を追いかけずに済むよう、`otel-env.sh` が
「原因の種類」→ ロガー名の対応を持っていて、`OTEL_TRACE_WARN_SUPPRESS` に
**グループ名を並べるだけ**で止められる。

| グループ | 止まる WARN | 既定 | 既定をそうしている理由 |
|---|---|---|---|
| `resource` | EC2 / ECS / EKS のメタデータが引けない | **ON** | Compose には `169.254.170.2` が無いので毎起動必ず出る。取れなくてもトレースは出る（資源属性が少し減るだけ） |
| `context` | `Scope.close` の呼び忘れ / Context 不整合 | **ON** | EAP の非同期処理で出る。アプリ側では直せず、リクエストごとに繰り返し出る |
| `export` | Collector へ送れない（接続拒否 / 5xx） | OFF | **「X-Ray に出ない」の最初の手掛かり**。起動直後だけのノイズなら `OTEL_WAIT_FOR_COLLECTOR=true` で待ってから起動する方が筋がよい |
| `sampler` | X-Ray 集中サンプリングのルール取得失敗 | OFF | サンプリングが既定値のまま = **意図した比率で採れていない**、という重要な事実 |
| `muzzle` | 計装の適用失敗（muzzle / tooling） | OFF | 特定の計装だけスパンが出ない原因がここに出る |

```yaml
    environment:
      OTEL_TRACE_WARN_SUPPRESS: resource,context,export   # 追加で export も黙らせる
      OTEL_TRACE_WARN_SUPPRESS: all                       # 全グループ
      OTEL_TRACE_WARN_SUPPRESS: off                       # グループ抑制を使わない
```

グループに無いロガーは `OTEL_AGENT_LOG_SUPPRESS_EXTRA` で名指しする
（既定の 2 件を残したまま足せる。`OTEL_AGENT_LOG_SUPPRESS_SPEC` を直接書くと既定が消える）。

```yaml
      OTEL_AGENT_LOG_SUPPRESS_EXTRA: "com.example.noisy=off,io.opentelemetry.sdk.trace=error"
```

何が効いたかは起動ログに全部出る。

```
[otel-env]   agent log suppress               = on (-D 10 件)
[otel-env]   trace WARN suppress (group)      = resource,context [level=error]
[otel-env]   suppressed loggers               = software.amazon...serviceevents=error,...
```

> **ロガー名を自分で書くときの注意。** エージェントは同梱する SDK / 計装ライブラリを
> 別パッケージへ再配置（シェーディング）するため、公式ドキュメントのクラス名を
> そのまま書いても実行時のロガー名と一致しない。`otel-env.sh` は
> `io.opentelemetry.instrumentation.**` → `io.opentelemetry.javaagent.shaded.instrumentation.**`、
> `io.opentelemetry.{api,context,sdk,exporter,contrib}.**` → `io.opentelemetry.javaagent.shaded.io.opentelemetry.**`
> の 2 規則で**再配置後の名前にも同じレベルを自動で付ける**ので、どちらの名前で書いても効く
> （`OTEL_AGENT_LOG_SHADED_ALIAS=false` で無効化）。

### なぜ 2 系統あるのか

- **A だけでは足りない場面がある。** `SERVER_SOURCE=image`（社内の EAP ランタイムイメージ）では既定の
  `standalone.xml` に別名のキーストア定義が入っていることがあり、リソース名を決め打ちした削除は空振りする。
  メッセージ ID を見る B は名前が変わっても効く。エージェント側も、版が上がって既定値が変われば A の前提が崩れる。
- **B だけでは足りない。** 「見えなくなった」だけで設定の矛盾は残る。ADOT の関数計装は
  「有効だが対象ゼロ」のまま、非推奨キーは 3.0 で削除されて意味を失う。A で状態そのものを正す。

### 抑制の効き方

- **ADOT エージェントのログは JBoss の logging サブシステムを通らない。**
  `OTEL_JAVAAGENT_LOGGING=simple` ではシェーディングされた slf4j-simple が stderr へ直接書くため、
  `standalone.xml` の `filter-spec` では止まらない。止められるのは JVM のシステムプロパティだけで、
  接頭辞は `io.opentelemetry.javaagent.slf4j.simpleLogger.log.<ロガー名>`（`otel-env.sh` が組み立てる）。
- **EAP 側は `filter-spec` で消す。** レベルを上げる（`org.wildfly.extension.elytron` を ERROR にする）と
  他の WARN まで消えるため、メッセージ ID を `not(any(match("WFLYELY00023"),match("WFLYELY01084")))` で
  名指しする。`jboss-logmanager` は発生元ロガーのフィルタしか見ない（root-logger に付けても効かない）ので、
  カテゴリと CONSOLE ハンドラの両方に入れてある。

### 環境変数 / ビルド引数

| 変数 | 既定 | 用途 |
|---|---|---|
| `APP_SERVICE_EVENT_PACKAGES` | 空 | ADOT の関数レベル計装を**使う**場合の対象パッケージ（例 `com.example.app`）。指定すると `..._FUNCTION_INSTRUMENT_ENABLED=true` が自動で付く。★スパン数＝X-Ray 課金が跳ねるので必ず絞る |
| `OTEL_AGENT_LOG_SUPPRESS` | `true` | エージェントログの直接抑制の ON/OFF。`false` にすると本来の WARN が見える（グループ抑制も止まる） |
| `OTEL_TRACE_WARN_SUPPRESS` | `resource,context` | トレース関連 WARN のグループ抑制。`resource` / `context` / `export` / `sampler` / `muzzle` のカンマ区切り、`all`、`off`。未知のグループ名は起動時にエラー（exit 44） |
| `OTEL_TRACE_WARN_SUPPRESS_LEVEL` | `error` | グループに適用するレベル。`error` = WARN 以下が消えて ERROR は残る。`off` にすると ERROR まで消える |
| `OTEL_AGENT_LOG_SUPPRESS_EXTRA` | 空 | 既定の 2 件を**残したまま**足す個別指定。`<ロガー名>=<レベル>,...` |
| `OTEL_AGENT_LOG_SUPPRESS_SPEC` | 上表の 2 件 | 既定の 2 件そのもの。**上書きすると既定が消える**ので、足すだけなら `_EXTRA` を使う |
| `OTEL_AGENT_LOG_SHADED_ALIAS` | `true` | 再配置後（シェーディング後）のロガー名にも同じレベルを自動で付ける |
| `OTEL_AGENT_LOG_LEVEL` | 未設定 | エージェントログ全体の下限（最終手段）。設定すると未知の WARN も見えなくなる |
| `APP_EXTRA_JAVA_OPTS` | 空 | 上記で足りないときの生の JavaOpts。`-Dio.opentelemetry.javaagent.slf4j.simpleLogger.log.<名前>=<レベル>` を直接書ける |
| `EAP_HTTPS_MODE` | `remove` | `remove`=既定 HTTPS 一式を削除 / `keystore`=8443 を残し起動時に `application.keystore` を生成 / `keep`=既定のまま（B のフィルタのみ）。★CLI が起動時適用になったので build-arg ではなく実行時の環境変数 |

抑制を一時的に外して素の出力を見るには:

```sh
docker compose run --rm -e OTEL_AGENT_LOG_SUPPRESS=false front

# HTTPS の扱いを変える (CLI は起動時適用なのでビルドし直さない)
EAP_HTTPS_MODE=keep docker compose up -d front
```

---

## 関連プロジェクト

| プロジェクト | 引き継いでいるもの |
|---|---|
| `Container_Compose_JBossEAP_Archive_Exploded_War` | UBI9.8 + OpenJDK21 + EAP8.1、archive 方式の `<fs-archive>` 配備、`readonlyRootFilesystem=true` 対応の `EAP_RUN_DIR` |
| `Container_ExtraSLB_JVM_https_outbounds` | base/front/back の 3 層構成、`embed-server` + `batch` での CLI 適用、`standalone_xml_history` 問題の回避 (本プロジェクトでは適用タイミングを起動時へ移し、履歴を作業領域に作って即消す形にしている)。外部 SLB のトラストストアはそちらの成果物を `jvm-env.sh` が拾う |
| `Docker_OpenTelemetry` | ADOT Java Agent の投入方法、Compose での Jaeger 併設 |
| `ADOT_Collector_Sidecar_Generator` | Collector 設定の Secrets Manager 配布、traces のみ有効化する方針 |
| `Container_Compose_ALB_Lambda` | `intra-api / intra-web / inter-api / sf-api` のサービス構成 |
