# Compose (Jaeger) と ECS (X-Ray) の差分・注意点

本構成は「同じイメージ・同じ加工処理で、送信先だけを差し替える」方針で作ってある。
差分は意外に少ないが、**残った差分はどれも “気づきにくい形で壊れる” もの**なので、
そこだけを正確に押さえる。

---

## 0. 差分の全体像

| 項目 | Compose / Jaeger | ECS / X-Ray | 差分の所在 |
|---|---|---|---|
| OTLP 送信先 | `http://adot-collector:4317` | `http://localhost:4317` | 環境変数 1 つ |
| front → back | `http://back:18080` | `http://localhost:18080` | 環境変数 1 つ |
| Collector exporter | `otlp/jaeger` + `debug` | `awsxray` | 設定ファイル |
| リソース検出 | `detectors: [env]` | `detectors: [env, ecs]` | 設定ファイル |
| 集中サンプリング | 無し (全量) | `awsproxy` + `sampler=xray` | 設定ファイル + 環境変数 |
| 認証 | 不要 | ECS タスクロール | IAM |
| トレース ID 形式 | 何でもよい | **先頭 4 バイトが epoch 秒** | ADOT エージェントが吸収 |
| 伝播ヘッダ | `traceparent` が主役 | `X-Amzn-Trace-Id` が主役 | 両方有効にして吸収 |
| annotation キー | 制約なし | `[A-Za-z0-9_]` のみ | transform で吸収 |
| Collector 設定の配布 | ファイルマウント | Secrets Manager → `AOT_CONFIG_CONTENT` | タスク定義 |

`otel/collector-xray.yaml` と `otel/collector-compose.yaml` の差分箇所には
すべて `★XRAY-DIFF` コメントが付けてある。それ以外は 1 文字も違わない。

---

## 1. ★最重要: トレース ID の形式

### 何が起きるか

X-Ray はトレース ID を次の形式として解釈する。

```
1-5759e988-bd862e3fe1be46a994272793
  ~~~~~~~~ ~~~~~~~~~~~~~~~~~~~~~~~~
  epoch秒   96bit のランダム値
  (16進8桁)  (16進24桁)
```

先頭 4 バイトが「そのトレースが始まった時刻」でなければならず、
現在時刻から大きく外れた ID のセグメントは **`InvalidTraceId` で捨てられる**。

OpenTelemetry 標準の `opentelemetry-javaagent.jar` は W3C 準拠の
**完全ランダムな 128bit** を採番する。これをそのまま X-Ray へ送ると
大半が捨てられる。

### なぜ気づきにくいか

- アプリのログには何も出ない (送信は成功している)
- X-Ray コンソールにも何も出ない (そもそもトレースが登録されない)
- **ADOT Collector のログにだけ**エラーが残る

Jaeger はランダム ID をそのまま受け付けるため、**ローカルでは完璧に動いて見える**。
本番に出した瞬間だけ何も出なくなる、という最悪の切り分けにくさになる。

### 対策

**`aws-opentelemetry-agent.jar` (ADOT 版) を使う。** これだけでよい。
ADOT エージェントは X-Ray 互換の ID ジェネレータを既定で組み込んでいる。
`base/Containerfile` はこれを `/opt/aws/aws-opentelemetry-agent.jar` に配置し、
`otel-env.sh` が `-javaagent` で読み込む。

> これが「標準エージェントではなく ADOT エージェントを使う」最大の理由。
> Jaeger しか使わないなら標準でも動くが、同じイメージを両方で使う以上
> ADOT に一本化する。

X-Ray 形式の ID は正当な 128bit ID なので、Jaeger 側も問題なく受け付ける。
つまり **ADOT に寄せておけば両対応になる**。

---

## 2. ★伝播ヘッダ: `X-Amzn-Trace-Id` と `traceparent`

### 経路によって使うヘッダが違う

| 経路 | 使われるヘッダ | Compose で再現できるか |
|---|---|---|
| front → back (Java 同士) | `traceparent` | できる |
| 利用者 → ALB → front | `X-Amzn-Trace-Id` (ALB が採番) | ALB スタブで再現 |
| EC2 バッチ → ALB → コンテナ | `X-Amzn-Trace-Id` (ALB が採番) | ALB スタブで再現 |
| Lambda → ALB → back | `X-Amzn-Trace-Id` (Lambda が注入) | Lambda スタブで再現 |
| SQS → Lambda | SQS システム属性 `AWSTraceHeader` | Lambda スタブで再現 |

**計装されていない呼び出し元 (バッチ・ブラウザ) が入口の経路は、
`X-Amzn-Trace-Id` を ALB が採番することで初めて 1 本のトレースになる。**
Compose に素の nginx を置いてもこれは再現できない。そのため
`sim/alb/alb_sim.py` が実 ALB と同じ書式で採番・透過する。

### 設定

```sh
OTEL_PROPAGATORS=xray,tracecontext,baggage
```

複合 propagator は「リスト順に extract して後勝ち」。
`xray,tracecontext` の順にすると:

- `traceparent` があればそれが勝つ (Java 同士は W3C)
- `X-Amzn-Trace-Id` しか無ければそれを使う (AWS 由来)

という自然な使い分けになる。

### 注意点

- **上流も下流も、同じ `OTEL_PROPAGATORS` にすること。**
  片側だけ `tracecontext` だと ALB を挟んだ瞬間にトレースが切れる。
  EC2 バッチや帳票 EC2 を後から計装する場合も必ず揃える。
- ALB は `traceparent` を素通しする。したがって front → ALB → back のような
  経路でも W3C は生き残る。

---

## 3. ★リソース属性は X-Ray では検索できない

`OTEL_RESOURCE_ATTRIBUTES` に入れた属性は「リソース属性」であり、
X-Ray のセグメントでは **metadata** 側に入る。metadata は目視できるが
**フィルタ式で検索できない**。

検索できるのは **annotation** だけで、annotation にするには
`awsxray` exporter の `indexed_attributes` に列挙する必要がある。
ただしこれは**スパン属性**を対象にするため、リソース属性のままでは届かない。

対策として `transform/xray-annotations` プロセッサで
リソース属性をスパン属性へ写している (`otel/collector-xray.yaml`)。

```yaml
- set(attributes["app_service"], resource.attributes["app.service"]) where ...
- set(attributes["app_role"],    resource.attributes["app.role"])    where ...
```

Jaeger にはこの区別が無い (リソース属性もタグとして検索できる) ため、
**ローカルでは transform が無くても動いてしまう**。
だからこそローカルの Collector でも同じ transform を通し、
「ローカルで見えた属性は X-Ray でも同じ名前で見える」状態を保っている。

### annotation キーの文字制限

X-Ray の annotation キーは `[A-Za-z0-9_]` のみ。
`service.namespace` → `service_namespace` のようにエクスポータが自動置換する。
置換後の名前が予想と違うと検索できないので、本構成では最初から
`app_service` / `app_role` のようなフラットな名前を作っている。

### annotation の個数上限

セグメントあたり **50 個**。`index_all_attributes: true` にすると
SQL 文や URL まで索引され上限に当たりやすい。明示列挙を使うこと。

---

## 4. ★サンプリングの考え方が違う

| | Compose / Jaeger | ECS / X-Ray |
|---|---|---|
| 方式 | クライアント側で固定 | X-Ray 集中サンプリング (推奨) |
| 設定 | `OTEL_TRACES_SAMPLER=parentbased_always_on` | `OTEL_TRACES_SAMPLER=xray` |
| ルール変更 | 再デプロイが必要 | X-Ray コンソールで即時反映 |
| Collector 側 | 不要 | `awsproxy` 拡張 (`:2000`) が必要 |
| IAM | 不要 | `GetSamplingRules` / `GetSamplingTargets` / `GetSamplingStatisticSummaries` |

`otel-env.sh` は `APP_ENV` から自動で選ぶ:

- `local` / `dev` → `parentbased_always_on` (全量)
- `stg` / `prd` → `xray` (集中サンプリング、`endpoint=http://localhost:2000`)

集中サンプリングにしておくと「障害調査中の 1 時間だけ 100% に上げる」が
再デプロイ無しでできる。`/api/health` を 0% にするルールも同様。

---

## 5. ★ヘルスチェックがトレースを埋め尽くす

ALB のヘルスチェックは既定 30 秒間隔、ECS のコンテナヘルスチェックも 30 秒間隔。
front/back × 4 サービス × タスク数ぶんが 24 時間動き続けるため、
放置すると X-Ray に記録されるトレースの大半が `/api/health` になる。

- 目的のトレースが埋もれて検索できない
- X-Ray の記録料金がヘルスチェックで消える

対策は 2 段構え:

1. **Collector の `filter/drop-healthcheck`** — 両環境で同じものを適用済み
2. **X-Ray 集中サンプリングのルール** — 本番のみ。アプリからの送信自体が止まる

さらに `healthcheck.sh` は `X-App-Caller: healthcheck` を付けているので、
万一漏れても `annotation.app_caller = "healthcheck"` で除外・特定できる。

---

## 6. Collector 設定の配布方法

| | Compose | ECS (Fargate) |
|---|---|---|
| 配布 | `volumes:` でファイルマウント | Secrets Manager → `AOT_CONFIG_CONTENT` |
| 起動 | `--config=/etc/otel/collector-compose.yaml` | `--config=env:AOT_CONFIG_CONTENT` |

Fargate はボリュームに設定ファイルを置く手段が限られるため、
`otel/collector-xray.yaml` の内容をそのまま Secrets Manager に格納し、
タスク定義の `secrets` で環境変数として注入する。

```sh
aws secretsmanager create-secret \
  --name /adot/collector-config/prd \
  --secret-string file://otel/collector-xray.yaml
```

---

## 7. IAM (ECS のみ)

**`taskRoleArn`** に付ける (`executionRoleArn` ではない):

| 権限 | 用途 |
|---|---|
| `xray:PutTraceSegments` | セグメント送信 |
| `xray:PutTelemetryRecords` | Collector のテレメトリ |
| `xray:GetSamplingRules` | 集中サンプリング |
| `xray:GetSamplingTargets` | 集中サンプリング |
| `xray:GetSamplingStatisticSummaries` | 集中サンプリング |

マネージドポリシー `AWSXRayDaemonWriteAccess` がこれらを含む。

`GetSampling*` を忘れると `OTEL_TRACES_SAMPLER=xray` が動かず、
**エージェントはフォールバックして全量送信する**。
「気づいたら X-Ray の料金が跳ねていた」という形で表面化するので注意。

---

## 8. ADOT サイドカーの `essential`

タスク定義で `"essential": false` にしてある。

Collector が落ちたときにアプリまで巻き添えで停止すると、
**可観測性のためのコンポーネントがサービス断の原因になる**。
逆に Collector が落ちればトレースは欠けるので、
`healthCheck` と CloudWatch アラームで検知する側に倒す。

---

## 9. 「X-Ray に出ない」ときの切り分け順序

| # | 確認 | 方法 |
|---|---|---|
| 1 | エージェントが読み込まれたか | アプリログの `[otel-env]` サマリに `-javaagent` があるか |
| 2 | `service.name` は正しいか | 同サマリの `OTEL_SERVICE_NAME` |
| 3 | Collector に届いているか | Collector のログ。`debug` exporter を一時的に追加する |
| 4 | Collector から X-Ray へ送れているか | Collector のログに `InvalidTraceId` / `AccessDenied` が無いか |
| 5 | ヘッダは来ているか | Undertow アクセスログの `xray` / `traceparent` フィールド (`00-server-common.cli`) |
| 6 | フィルタで捨てていないか | パスが `/api/health` にマッチしていないか |
| 7 | サンプリングで落ちていないか | X-Ray コンソールのサンプリングルール |

アクセスログには `X-Amzn-Trace-Id` と `traceparent` と `X-App-Caller` を
出すようにしてある (`base/cli/00-server-common.cli`)。
「そもそもヘッダが来ていないのか、来ているのに送信できていないのか」を
awslogs だけで切り分けられる。
