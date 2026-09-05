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
| 共通シェル | `jvm-env.sh` → `otel-env.sh`。JVM と OpenTelemetry の環境変数を 1 か所で組み立てる |
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
    jvm-env.sh              ★ JVM 環境変数の共通シェル
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
    apply-cli.sh            ビルド時に embed-server で CLI を適用
    standalone.conf.append  JAVA_OPTS_APPEND フック

front/  back/             各ロールの Containerfile と固有 CLI
sample-app/               全経路を叩く検証用 WAR (実 WAR に差し替え可)

otel/
  collector-xray.yaml     ★ 本番 ECS 用 (awsxray)
  collector-compose.yaml  ★ ローカル用 (Jaeger)   ← 差分は ★XRAY-DIFF のみ

sim/                      ローカル専用スタブ (ALB / Lambda / 帳票EC2 / バッチ)
ecs/                      タスク定義テンプレート
scripts/                  build / up / down / smoke-trace / gen-taskdefs / drift check
docs/
  naming-convention.md    ★ 命名規約と X-Ray での検索方法
  xray-vs-jaeger.md       ★ Compose と X-Ray の差分・注意点
  trace-paths.md          ★ 6 経路それぞれの伝播の仕組み
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

### 2. 計装していない相手のノード名も環境変数だけで決まる

Aurora / Valkey / 帳票 EC2 / 外部 SLB は計装できない。既定ではマップに
`aurora-xxx.cluster-abc.ap-northeast-1.rds.amazonaws.com` のような FQDN が並ぶ。

`otel-env.sh` が接続先ホストの環境変数から
`OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING` を組み立てるので、
**アプリのコードを 1 行も触らずに** `aurora-mysql` / `elasticache-valkey` /
`report-ec2` / `external-slb` という運用上の呼び名に揃う。

アプリが接続に使うホスト名とマッピングのキーが同じ環境変数から来るため、
両者がずれることが構造的に起きない。

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
| `JAVA_OPTS` を直接渡さない | standalone.conf が既定値を組み立てなくなり `--add-opens` 等が消える。`JAVA_OPTS_APPEND` を使う |
| `JAVA_TOOL_OPTIONS` を使わない | `jboss-cli.sh` まで計装され、CLI が遅くなり無意味なスパンが出る。`-javaagent` は `JAVA_OPTS_APPEND` へ |
| `JBOSS_MODULES_SYSTEM_PKGS` | `io.opentelemetry.javaagent` を追加必須。無いとクラスローダ隔離で `NoClassDefFoundError` |
| EAP 内蔵 opentelemetry サブシステム | Java Agent と二重計装になりスパンが 2 本出る。`10-remove-mp-opentelemetry.cli` で外す |
| `OTEL_SERVICE_NAME` を必ず明示 | エージェントはデプロイ名から service.name を推測する。明示しないと 4 サービスぶんの front が全部 `front` という 1 ノードに潰れる |
| CLI はビルド時に適用 | 起動時 `embed-server` は設定ブートストラップを 2 回にし、`standalone_xml_history` の rename が Compose では警告・ECS では起動失敗という環境差を生む |
| Valkey は Jedis / Lettuce で | `valkey-java` はエージェントの計装対象外。使うとキャッシュアクセスのスパンが一切出ない |
| コンテキストルートを分ける | front=`/front` / back=`/back`。実 ALB はパスを書き換えず転送するため、両方 `/app` だとパスベースのルールで振り分けられない |

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
| `OTEL_AGENT_LOG_SUPPRESS` | `true` | エージェントログの直接抑制の ON/OFF。`false` にすると本来の WARN が見える |
| `OTEL_AGENT_LOG_SUPPRESS_SPEC` | 上表の 2 件 | `<ロガー名>=<レベル>,...`。レベル省略時は `error`。ロガー名はパッケージ単位でも可 |
| `OTEL_AGENT_LOG_LEVEL` | 未設定 | エージェントログ全体の下限（最終手段）。設定すると未知の WARN も見えなくなる |
| `EAP_HTTPS_MODE` (build-arg) | `remove` | `remove`=既定 HTTPS 一式を削除 / `keystore`=8443 を残しビルド時に `application.keystore` を生成 / `keep`=既定のまま（B のフィルタのみ） |

抑制を一時的に外して素の出力を見るには:

```sh
docker compose run --rm -e OTEL_AGENT_LOG_SUPPRESS=false front
docker build -f base/Containerfile --build-arg EAP_HTTPS_MODE=keep -t app-eap-base:1.0 .
```

---

## 関連プロジェクト

| プロジェクト | 引き継いでいるもの |
|---|---|
| `Container_Compose_JBossEAP_Archive_Exploded_War` | UBI9.8 + OpenJDK21 + EAP8.1、archive 方式の `<fs-archive>` 配備、`readonlyRootFilesystem=true` 対応の `EAP_RUN_DIR` |
| `Container_ExtraSLB_JVM_https_outbounds` | base/front/back の 3 層構成、CLI のビルド時適用、`standalone_xml_history` 問題の回避。外部 SLB のトラストストアはそちらの成果物を `jvm-env.sh` が拾う |
| `Docker_OpenTelemetry` | ADOT Java Agent の投入方法、Compose での Jaeger 併設 |
| `ADOT_Collector_Sidecar_Generator` | Collector 設定の Secrets Manager 配布、traces のみ有効化する方針 |
| `Container_Compose_ALB_Lambda` | `intra-api / intra-web / inter-api / sf-api` のサービス構成 |
