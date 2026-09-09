# ALB を挟んだ EC2 通信がトレース上どう見えるか

「実際の通信先は EC2 だが、間に ALB が入る」構成で、
**自動計装だけで**どこまで見えるか / 見えないか。

---

## 0. 結論を先に

| 問い | 答え |
|---|---|
| ALB のノードがサービスマップに出るか | **出ない。** ALB は X-Ray にセグメントを送らない |
| ALB を 1 ノードとして見せられるか | **できる。** こちらの `peer.service` を ALB の名前にする |
| ALB の先の EC2 までトレースを繋げられるか | **できる。ただし EC2 側にもエージェントが要る。** アプリ改修は不要 |
| EC2 に入れられない場合は | ノードは 1 個のまま。ALB とターゲットの内訳は X-Ray だけでは分離できない |
| 内訳を知る方法は | ALB アクセスログの `target_processing_time` と突き合わせる (結合キーは用意済み) |
| ALB の裏のどのサーバが応答したか | **ターゲットが名乗れば分かる。** ALB は教えてくれない |

---

## 1. ALB は X-Ray に何もしない

これが出発点になる事実。

| AWS サービス | X-Ray にセグメントを送るか |
|---|---|
| API Gateway | 送る (ノードが自動で出る) |
| AppSync | 送る |
| Lambda | 送る (アクティブトレース有効時) |
| **ALB / NLB** | **送らない** |

ALB がトレースについてやることは 1 つだけ。

> **`X-Amzn-Trace-Id` が無ければ採番して付与し、あればそのまま透過する。**

これは「計装されていない呼び出し元 (ブラウザ・EC2 バッチ) が入口でも
1 本のトレースになる」ために決定的に重要な働きだが、
**ALB 自身のノードやレイテンシは X-Ray に一切現れない。**

したがってマップに出るのは、こちらのクライアントスパンから作られる
**推定ノードが 1 個だけ**になる。

```
intra-api-front ──▶ (推定ノード 1 個)
                     ↑
                     ここに ALB と EC2 の両方の時間が入っている
```

---

## 2. その 1 個のノードに何と名付けるか

`APP_PEER_ALB_MODE` で選ぶ。判定の仕組みは
`docs/peer-service-resolution.md`。

### `upstream` (既定) — ALB を透過扱いする

```
intra-api-front ──▶ report-ec2
```

ALB は「単なる経路」とみなし、**業務上の相手** の名前を付ける。
マップが業務の構成図に近くなるので、普段はこちらが読みやすい。

### `alb` — ALB 自体をノードにする

```
intra-api-front ──▶ report-alb
```

「どの ALB で詰まっているか」を見たいとき、
あるいは 1 つの ALB が複数のターゲットグループへ振り分けていて
**ALB という単位で束ねたい**ときはこちら。

```sh
# .env
APP_PEER_ALB_MODE=alb
```

> どちらを選んでも、**ALB のノードが AWS 側から生えてくるわけではない。**
> 名前が変わるだけで、中身は「こちらのクライアントスパン 1 本」のまま。

---

## 3. ALB の先の EC2 まで繋ぐ (自動計装だけで可能)

**可能。EC2 側の JVM に同じ ADOT Java Agent を入れるだけ。**
帳票アプリのコードは 1 行も変えない。

```sh
# 帳票 EC2 の起動スクリプト
export OTEL_SERVICE_NAME=report-ec2                    # ★ 下の注意を読むこと
export OTEL_PROPAGATORS=xray,tracecontext,baggage      # ★ コンテナ側と必ず同じ
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_TRACES_EXPORTER=otlp
java -javaagent:/opt/aws/aws-opentelemetry-agent.jar -jar report.jar
```

EC2 には ADOT Collector を常駐させ、そこから X-Ray へ送る
(タスク内サイドカーと同じ設定でよい)。

これでマップはこうなる。

```
intra-api-front ──▶ report-ec2
                     ↑ 中身が見える。DB アクセスや外部呼び出しまで辿れる
```

### ★ `OTEL_SERVICE_NAME` は `peer.service` と同じ文字列にする

ここを外すと **同じ相手が 2 ノードに割れる。**

- こちらのクライアントスパンが作る推定ノード … `peer.service` の値
- EC2 のサーバスパンが作る実ノード … `service.name` の値

X-Ray は名前が一致するノードを 1 つに束ねる。
違う文字列だと `report-ec2` と `report-alb` のような 2 ノードが
並んで出る。

したがって EC2 を計装する場合は:

| 設定 | 値 |
|---|---|
| EC2 の `OTEL_SERVICE_NAME` | `report-ec2` |
| コンテナ側 `APP_PEER_ALB_MODE` | `upstream` (既定) → `peer.service` = `report-ec2` |

**`alb` モードと EC2 の計装は併用しない。**
`alb` モードにすると `peer.service` が `report-alb` になり、
EC2 の `report-ec2` と一致しなくなる。

### 上流 (EC2 バッチ) を計装する場合も同じ

`OTEL_PROPAGATORS` を **必ず** コンテナ側とそろえる。
片側だけ `tracecontext` だと ALB を挟んだ瞬間にトレースが切れる。

---

## 4. EC2 に入れられない場合に取れる情報

計装できない相手でも、**自動計装の範囲だけで**ここまで分かる。

### 4-1. ALB の裏で実際に応答したサーバ (`app_upstream`)

ALB は「どのターゲットへ振ったか」を教えてくれない。
**ターゲット側が名乗るしかない。**

ターゲットがレスポンスヘッダを返せば、ALB はそれを素通しするので、
こちらの HTTP クライアント計装が拾える。

```
X-Server-Id: report-ec2@ip-10-0-1-23
```

| 設定 | 場所 |
|---|---|
| `x-server-id` をレスポンスヘッダで返す | ターゲット (EC2) 側 |
| `x-server-id` を取り込む | `APP_CAPTURE_CLIENT_RESPONSE_HEADERS` (既定に入っている) |
| `app_upstream` に写す | Collector の `transform/peer-service-resolve` |

実機での付け方 (アプリ改修不要):

```apache
# Apache
Header always set X-Server-Id "report-ec2@%{HOSTNAME}e"
```

```nginx
# nginx
add_header X-Server-Id "report-ec2@$hostname" always;
```

これで `front ──▶ report-ec2` というエッジ 1 本しか無くても、

```
annotation.app_upstream = "report-ec2@ip-10-0-1-23"
```

で **どの EC2 が遅いのか** まで絞り込める。
ローカルでは `sim/report-ec2/stub.py` が同じヘッダを返すので、
Jaeger で先に形を確認できる。

### 4-2. ALB の手前の実クライアント (`client_ip` / `client_proto`)

ALB を挟むと `http.client_ip` は **ALB の IP** になる。
利用者の IP は `X-Forwarded-For` の **先頭**にしか無い。

| annotation | 元 |
|---|---|
| `client_ip` | `X-Forwarded-For` の先頭の IP |
| `client_proto` | `X-Forwarded-Proto` (利用者側が https だったか) |
| `http_host` | `Host` (1 つの ALB に複数ドメインを載せている場合) |

> `base/cli/00-server-common.cli` が Undertow の
> `proxy-address-forwarding=true` を入れているので、EAP 内部の
> リモートアドレスも復元される。annotation 側と二重で押さえている。

### 4-3. ALB を通ったかどうか (`app_via`)

```
annotation.app_via = "alb"
```

- クライアントスパン: 接続先が `*.elb.amazonaws.com`、
  または `peer.service` が `-alb` で終わる
- サーバスパン: `X-Forwarded-For` が付いている
  (ALB / プロキシを通ったリクエストにしか付かない)

「ALB 経由の流入だけ」「タスク内の直呼びだけ」を分けて見られる。

### 4-4. ALB での待ち時間を EC2 の処理時間と分ける (`alb_trace_id`)

**X-Ray だけでは分離できない。** ALB がセグメントを送らない以上、
クライアントスパンの所要時間には

```
DNS + 接続 + ALB のキューイング + ALB→ターゲット + ターゲットの処理 + 応答
```

が全部入る。分離するには ALB アクセスログ (S3) と突き合わせる。

ALB アクセスログの列:

| 列 | 意味 |
|---|---|
| `request_processing_time` | ALB が受けてからターゲットへ送るまで |
| `target_processing_time` | **ターゲットの処理時間** |
| `response_processing_time` | ターゲットの応答を受けてから返すまで |
| `trace_id` | `Root=1-...` の文字列 |

結合キーはこちらのスパンに残してある。

```
annotation.alb_trace_id = "Root=1-68bf1234-abcdef0123456789abcdef01"
```

手順:

1. X-Ray / Jaeger で遅いスパンを見つけ、`alb_trace_id` を控える
2. Athena で ALB アクセスログを引く

```sql
SELECT time, request_processing_time, target_processing_time,
       response_processing_time, target_status_code, target_ip_port
FROM   alb_logs
WHERE  trace_id = 'Root=1-68bf1234-abcdef0123456789abcdef01';
```

`target_processing_time` が大きければターゲットが遅い。
小さいのにクライアントスパンが長ければ、ALB の手前
(接続確立・キューイング・ターゲットの枯渇) を疑う。

> `alb_trace_id` はサーバスパンの `X-Amzn-Trace-Id` ヘッダから採っている。
> X-Ray のトレース ID (`1-...` のみ) とは別物なので混同しないこと。
> ALB のログに出るのは `Root=` 付きの文字列そのもの。

---

## 5. まとめ: 経路ごとの見え方

```
利用者 / EC2バッチ                 ALB                     ECS タスク
    │  (計装されていない)           │                          │
    │ ─────────────────────────▶  │                          │
    │   traceparent 無し           │ X-Amzn-Trace-Id を採番    │
    │                              │ ────────────────────────▶│ front
    │                              │   X-Forwarded-For を付与  │  (SERVER スパン)
    │                              │                          │  app_via=alb
    │                              │                          │  client_ip=利用者IP
    │                              │                          │
    │                              │◀──────────────────────── │ front
    │                              │   traceparent +           │  (CLIENT スパン)
    │                              │   X-Amzn-Trace-Id を送出  │  peer.service=report-ec2
    │                              │ ────────────────────────▶│  app_via=alb
    │                              │        帳票 EC2           │  app_upstream=…
```

| 見たいもの | 見えるか | 手段 |
|---|---|---|
| 利用者 → front が 1 本のトレースか | 見える | ALB の `X-Amzn-Trace-Id` + `xray` propagator |
| 利用者の IP | 見える | `client_ip` |
| ALB 経由かどうか | 見える | `app_via` |
| 帳票 EC2 の応答時間 (ALB 込み) | 見える | クライアントスパンの duration |
| **ALB と EC2 の内訳** | **X-Ray では見えない** | ALB アクセスログ + `alb_trace_id` |
| どの EC2 が応答したか | 見える (ターゲットが名乗れば) | `app_upstream` |
| **EC2 の中で何が遅いか** | **EC2 を計装すれば見える** | 3. の手順 |
| ALB のノードそのもの | 出ない | ALB は X-Ray にセグメントを送らない |

---

## 6. ローカルで確認する

`sim/alb/alb_sim.py` は実 ALB のトレース関連の挙動 (採番・透過・
`X-Forwarded-*` の付与・**ターゲットのレスポンスヘッダの素通し**) を
再現してある。「実 ALB がやらないこと」も同じくやらない。

```sh
docker compose up -d
./scripts/smoke-trace.sh
docker compose logs --tail=30 alb
```

```
[alb] GET /report/daily -> report-ec2:8000  trace=Root=1-... (passthrough) caller=user xff=172.20.0.5
[alb]    <- 200 server_id=report-ec2@a1b2c3d4e5f6
```

Jaeger (http://localhost:16686) の Tags で:

```
app_via=alb
app_upstream=report-ec2@a1b2c3d4e5f6
client_ip=172.20.0.5
alb_trace_id=Root=1-...
app_peer=report-ec2        (APP_PEER_ALB_MODE=alb なら report-alb)
```

`APP_PEER_ALB_MODE` を切り替えて `app_peer` が
`report-ec2` ↔ `report-alb` と変わることも確認できる。

```sh
APP_PEER_ALB_MODE=alb docker compose up -d front back
```

**Jaeger の Tags で引けないものは、X-Ray でも annotation にならない。**
