# 通信経路ごとのトレース伝播

対象の 6 経路それぞれについて「何がスパンを作り」「何がコンテキストを運び」
「X-Ray でどう見えるか」をまとめる。

---

## 全体像

```
                      ┌──────────────────────────── ECS タスク (awsvpc) ───┐
利用者 ──▶ ALB ──────▶│ front (8080)                                       │
                      │   │                                                │
EC2バッチ ──▶ ALB ───▶│   ├──▶ back (localhost:18080)                     │
                      │   │      │                                         │
        ┌─────────────│   │      │                                         │
        │             │   │      ├──▶ Aurora Serverless v2 (MySQL 8.4)     │
        │             │   │      ├──▶ ElastiCache for Valkey               │
        │             │   │                                                │
        │             │   ├──▶ ALB ──▶ 帳票EC2                             │
        │             │   ├──▶ 外部SLB ──▶ VPC外                           │
        │             │   └──▶ SQS ─┐                                      │
        │             │             │   adot-collector (localhost:4317)    │
        │             └─────────────│──────────────┬───────────────────────┘
        │                           ▼              ▼
        └──── ALB ◀── Lambda ◀── SQSトリガ      AWS X-Ray
```

---

## 経路 1: front → back (ECS タスク内)

| | |
|---|---|
| スパン | front: HTTP CLIENT / back: HTTP SERVER |
| 伝播 | `traceparent` (W3C)。ADOT エージェントが自動注入 |
| 接続先 | ECS: `http://localhost:18080` / Compose: `http://back:18080` |
| 設定 | `BACKEND_URL`, `BACKEND_HOST` |

awsvpc モードではタスク内の全コンテナが 1 つのネットワーク名前空間を共有するので
`localhost` で届く。ADOT サイドカーへの `localhost:4317` も同じ理屈。

**X-Ray での見え方**: `intra-api-front` → `intra-api-back` のエッジ。

**注意**: front と back が同じポートを listen すると
`Address already in use` で後勝ち起動失敗する。だから back は 18080。

---

## 経路 2: front/back → Aurora Serverless v2 (MySQL 8.4)

| | |
|---|---|
| スパン | JDBC CLIENT (`db.system=mysql`) + DataSource 取得スパン |
| 伝播 | 無し (DB は計装対象外なのでここでトレースは終端) |
| 設定 | `DB_HOST`, `20-datasource-aurora.cli`, `OTEL_INSTRUMENTATION_JDBC_DATASOURCE_ENABLED=true` |

**X-Ray での見え方**: `aurora-mysql` という下流ノード (`peer.service` 由来)。
`Database::SQL` 種別のサブセグメント。

**Aurora Serverless v2 固有の注意**:
ACU が 0 付近から立ち上がるとき接続取得が数秒ブロックする。
`OTEL_INSTRUMENTATION_JDBC_DATASOURCE_ENABLED=true` にしてあるので
「SQL は 5ms なのに接続取得が 3s」が X-Ray 上で分離して見える。
これが無いと「原因不明の遅い DB アクセス」にしか見えない。

SQL のリテラルは `db-statement-sanitizer` が `?` に伏せるため、
個人情報が X-Ray に出ることはない。

---

## 経路 3: front/back → ElastiCache for Valkey

| | |
|---|---|
| スパン | Redis CLIENT (`db.system=redis`) |
| 伝播 | 無し (終端) |
| 設定 | `VALKEY_HOST`, `VALKEY_PORT` |

**X-Ray での見え方**: `elasticache-valkey` という下流ノード。

**★ クライアントライブラリの選択が重要**:
Valkey は Redis プロトコル互換なので、**Jedis または Lettuce** で接続する。
これらは ADOT エージェントの計装対象なのでスパンが出る。
`valkey-java` クライアントは現時点で計装対象に入っていないため、
**使うとスパンが一切出ない**。「Valkey だから valkey-java」と選ぶと
X-Ray からキャッシュアクセスが丸ごと消える。

---

## 経路 4: front/back → ALB → 帳票 EC2 サーバ

| | |
|---|---|
| スパン | HTTP CLIENT (コンテナ側のみ) |
| 伝播 | `traceparent` + `X-Amzn-Trace-Id` を送出。ALB は両方素通し |
| 設定 | `REPORT_ALB_HOST`, `REPORT_ALB_URL` |

**X-Ray での見え方**: `report-ec2` という下流ノード。
帳票 EC2 が計装されていないので、**そのノードの内側は見えない**
(帳票生成に何秒かかったかは分かるが、その内訳は分からない)。

**帳票 EC2 も計装したい場合**:
同じ ADOT Java Agent を EC2 上の JVM に入れる。EC2 に ADOT Collector を
常駐させ、そこから X-Ray へ送る。`OTEL_PROPAGATORS` を
コンテナ側と揃えれば 1 本のトレースとして繋がる。

```sh
export OTEL_SERVICE_NAME=report-ec2
export OTEL_PROPAGATORS=xray,tracecontext,baggage   # ★ 必ず揃える
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
java -javaagent:/opt/aws/aws-opentelemetry-agent.jar -jar report.jar
```

---

## 経路 5: EC2 バッチサーバ → ALB → コンテナ

| | |
|---|---|
| スパン | コンテナ側の HTTP SERVER のみ |
| 伝播 | **ALB が採番した `X-Amzn-Trace-Id`** |
| 設定 | `OTEL_PROPAGATORS` に `xray` が含まれること |

**★ この経路が `xray` propagator を必須にしている理由。**

バッチサーバは計装されていないので `traceparent` を送ってこない。
それでも X-Ray 上で 1 本のトレースになるのは、**ALB が
`X-Amzn-Trace-Id: Root=1-<epoch>-<random>` を採番して付与するから**。
コンテナ側は `xray` propagator でこれを読み、トレースの起点にする。

`OTEL_PROPAGATORS` から `xray` を外すと、バッチ経由のリクエストが
すべて別々のトレースに割れる。

**X-Ray での見え方**: バッチサーバのノードは**出ない**
(計装されていないので存在を知りようがない)。マップは
`intra-api-front` から始まっているように見える。

**誰が叩いたかを分かるようにする**:
バッチが `X-App-Caller: batch-ec2` ヘッダを付ける。コンテナ側は
`OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_REQUEST_HEADERS=x-app-caller` で
スパン属性に取り込み、Collector が annotation `app_caller` に昇格させる。

```
annotation.app_caller = "batch-ec2"
```

これでバッチ由来のトレースだけを一覧できる。
ALB を挟むと呼び出し元が分からなくなる問題への、コードを触らない答え。

**バッチも計装する場合 (推奨)**: 経路 4 と同じ手順。
バッチ自身のノードがサービスマップに出るようになる。

---

## 経路 6: front/back → SQS → Lambda → ALB → back

**最も切れやすい経路。** HTTP と違いキューには「呼び出し元のスレッド」が
存在しないため、トレースは必ず一度切れる。繋ぐには 3 段すべてが揃う必要がある。

### 段 1: 送信側がメッセージにコンテキストを書く

```sh
OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_USE_PROPAGATOR_FOR_MESSAGING=true
```

AWS SDK v2 の計装が `SendMessage` に割り込み、設定済み propagator
(`xray` を含む) でメッセージへ書き込む。

**X-Ray 方式では SQS の *システム属性* `AWSTraceHeader` が使われる。**
これは通常のメッセージ属性 10 個の上限に含まれない (重要 — 業務用の
メッセージ属性が既に 10 個あっても入る)。

スパン: `PRODUCER` (`messaging.system=aws.sqs`)。

### 段 2: Lambda が読み取り、自分のトレースの親にする

本番: ADOT Lambda レイヤー + `AWS_LAMBDA_EXEC_WRAPPER=/opt/otel-handler`。

```
Layer: arn:aws:lambda:<region>:901920570463:layer:aws-otel-java-agent-amd64-ver-1-32-0:<n>
Env:   AWS_LAMBDA_EXEC_WRAPPER = /opt/otel-handler
       OTEL_PROPAGATORS        = xray,tracecontext,baggage
       OTEL_EXPORTER_OTLP_ENDPOINT = (レイヤ内蔵 Collector が受ける)
Tracing: Active
```

Lambda の「アクティブトレース」を有効にすると、Lambda サービス自身も
`AWSTraceHeader` を見て親子を繋ぐ。

**自前でポーリングする場合の落とし穴**:
`ReceiveMessage` で `AttributeName=AWSTraceHeader` を明示的に要求しないと
システム属性は返ってこない。「送信側は正しいのに Lambda 側で拾えない」
という形で表面化する。(`sim/lambda/sqs_to_alb.py` に実装例)

### 段 3: Lambda が下流へ `X-Amzn-Trace-Id` を付ける

ADOT レイヤーが自動注入する。ALB は既にヘッダがあれば透過するので、
back まで同じトレース ID が届く。

### 繋がらないときの見分け方

X-Ray 上で **トレースが 2 本に割れる**:

- 1 本目: front の `SendMessage` で終わる
- 2 本目: back から始まる

この形が出たら段 1 か段 2 が壊れている。
`sim/lambda/sqs_to_alb.py` はコンテキストが取れなかった場合に
警告ログを出すようにしてあるので、ローカルで先に潰しておける。

---

## 経路 7: front/back → 外部 SLB → VPC 外

| | |
|---|---|
| スパン | HTTP CLIENT のみ |
| 伝播 | ヘッダは送るが、相手が読む保証はない |
| 設定 | `EXTERNAL_SLB_HOST`, `EXTERNAL_SLB_URL` |

**X-Ray での見え方**: `external-slb` という下流ノード。

**注意点**:

- 実際は HTTPS になる。トラストストアの作り込みは別プロジェクト
  (`Container_ExtraSLB_JVM_https_outbounds`) が担当。本構成は
  `jvm-env.sh` が `EXTRASLB_TRUSTSTORE_PATH` を検出したときだけ
  `-Djavax.net.ssl.trustStore=` を付ける形で連携している。
- **TLS ハンドシェイクの時間もクライアントスパンに含まれる。**
  外部 SLB のノードが遅く見えるとき、相手が遅いのか
  ハンドシェイクが遅いのかは X-Ray だけでは分離できない。
  JVM の TLS デバッグログと併用する。
- こちらのトレースコンテキストが外部へ漏れることを気にする場合は、
  そのホストだけ propagator を無効化する手段は無いため、
  必要ならアプリ側で専用の HTTP クライアントを分ける。

---

## まとめ: 各経路が依存している設定

| 経路 | 依存している設定 | 外すとどうなるか |
|---|---|---|
| front→back | `OTEL_PROPAGATORS` に `tracecontext` | トレースが割れる |
| →Aurora | `peer-service-mapping` の `DB_HOST` | ノード名が FQDN になる |
| →Aurora | `JDBC_DATASOURCE_ENABLED` | プール待ちが見えない |
| →Valkey | Jedis / Lettuce を使うこと | スパンが一切出ない |
| →帳票EC2 | `peer-service-mapping` の `REPORT_ALB_HOST` | ノード名が FQDN になる |
| バッチ→ | `OTEL_PROPAGATORS` に `xray` | トレースが割れる |
| バッチ→ | `capture-request-headers` | 呼び出し元が分からない |
| →SQS→Lambda | `USE_PROPAGATOR_FOR_MESSAGING` | トレースが 2 本に割れる |
| 全経路 | ADOT 版エージェント | X-Ray が ID を捨てる (Jaeger では動く) |
