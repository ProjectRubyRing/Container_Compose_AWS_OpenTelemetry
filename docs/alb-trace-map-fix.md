# ALB 経由の EC2 呼び出しで「Client から直接線が引かれる」問題の修正

ECS タスク内の front → ALB → EC2 (Java API サーバ :8080) の呼び出しが、
X-Ray のトレースマップ上で **front を経由せず `Client` から直接** 下流ノードへ
線が引かれて見える問題への対応。修正箇所と理由をこの 1 ファイルにまとめる。

---

## 0. 結論

| | 修正前 | 修正後 |
|---|---|---|
| 線の起点 | `Client` | **`intra-api-front`** (front コンテナ) |
| 下流ノード名 | `ec2_server` (ALB の裏だと読めない) | **`ec2_server@report-alb`** (= report-alb の裏の ec2_server) |
| 修正量 | | 5 ファイル・追加 48 行 / 削除 4 行 (コメント込み)。新しい仕組みは足さず、既存の `transform/peer-service-resolve` と `APP_PEER_ALB_MODE` を拡張しただけ |

```
修正前                                     修正後
  Client ──▶ ec2_server                      Client ──▶ intra-api-front ──▶ ec2_server@report-alb
  (front が出てこない / ALB の裏と読めない)    (front から線が出る / ALB の裏の EC2 と読める)
```

> ★ **前提の問題がある (9 章):** リポジトリで固定している ADOT Collector
> (`aws-otel-collector:v0.43.3`) には `transform` プロセッサが入っていない。
> 今回の修正に限らず、既存の `transform/*` もその版では動かない (起動時にエラーで止まる)。
> 反映の前に 9 章を読むこと。

---

## 1. 原因

### 1-1. 親の無い CLIENT スパンは「入口のサービス」扱いになる

awsxray exporter (Collector) は、スパンを X-Ray のセグメントへ変換するとき
次のように振り分ける
(`exporter/awsxrayexporter/internal/translator/segment.go` の `MakeSegment`)。

| スパン | X-Ray 上の扱い | 名前 |
|---|---|---|
| SERVER スパン | セグメント (サービスのノード) | `service.name` → `intra-api-front` |
| 親のある CLIENT スパン | その親の **サブセグメント** (`namespace: remote`) | `peer.service` |
| **親の無い CLIENT スパン** | **独立したセグメント** | **`peer.service`** |

最後の行が問題だった。親の無い CLIENT スパンは `peer.service`
(例: `ec2_server`) を名前にした **親の無いセグメント** になる。
X-Ray は親の無いセグメントを「トレースの入口にいるサービス」とみなし、
上流に `Client` ノードを付ける。結果として

```
Client ──▶ ec2_server        ← 実際には front が呼んでいるのに front が出てこない
```

という形になる。しかもこのノードの origin は front 側のリソース属性から
`AWS::ECS::Container` になるので、「ECS コンテナの形をした ec2_server」という
何を指すのか分からないノードになる。

### 1-2. どういうときに CLIENT スパンの親が無くなるか

受けた HTTP リクエスト (= SERVER スパン) の **外側で** 下流を呼んだとき。

- スケジューラ / タイマー (EJB `@Schedule`、Quartz、`ScheduledExecutorService` など)
- 起動時の処理 (`@Startup`、初期化時の疎通確認など)
- コンテキストを引き継がないスレッドから呼んだとき

サンプルアプリの `/api/report` のように SERVER スパンの中から呼ぶ場合は、
もともと `intra-api-front ──▶ ec2_server` と正しく出る (修正前後で変わらない)。

### 1-3. ノード名から ALB の裏の EC2 だと読めない

既存の `APP_PEER_ALB_MODE` には次の 2 つしかなかった。

- `upstream` (既定) → `ec2_server` : EC2 だとは分かるが、ALB の裏だとは読めない
- `alb` → `report-alb` : ALB だとは分かるが、裏の EC2 が消える

---

## 2. 修正方針 (2 点)

| # | 目的 | 手段 | 場所 |
|---|---|---|---|
| A | 線を front から引く | 親の無い CLIENT / PRODUCER / INTERNAL スパンに `aws.span.kind=LOCAL_ROOT` と `aws.local.service=<service.name>` を付ける。awsxray exporter はこの印があると **「自サービスのセグメント + 下流のサブセグメント」** に分けて出す (Application Signals 用に用意された既存の仕組み) | Collector `transform/peer-service-resolve` に 2 行 |
| B | ノード名で「ALB の裏の EC2」と読めるようにする | `APP_PEER_ALB_MODE` に `both` を追加し、ノード名を `<PEER_NAME_EC2>@<PEER_NAME_ALB>` (既定 `ec2_server@report-alb`) にする | `otel-env.sh` の既存の判定表 |

A は Collector だけ、B はコンテナ (エージェント) 側だけで効く。
**アプリ (WAR) のコードは 1 行も変えていない。**

---

## 3. 修正箇所一覧

| ファイル | 変更内容 | 行 |
|---|---|---|
| `otel/collector-xray.yaml` | 修正 A: `transform/peer-service-resolve` の末尾に 2 行 + 説明コメント | 299–313 |
| `otel/collector-compose.yaml` | 修正 A: 同じ 2 行 (X-Ray 版と完全一致。`check-collector-drift.sh` で担保) | 266–274 |
| `base/bin/otel-env.sh` | 修正 B: `APP_PEER_ALB_MODE=both` の受け付け・名前の組み立て・起動ログ・コメント | 282–287, 302–303, 315, 650–657, 1322 |
| `ecs/taskdef.template.json` | 修正 B を本番で有効にする: front に `APP_PEER_ALB_MODE=both` | 119–120 |
| `.env.example` | `both` の説明を追記 (ローカルは既定 `upstream` のまま) | 68–70 |
| `docs/alb-trace-map-fix.md` | 本ファイル (新規) | — |

---

## 4. 修正の詳細

### 4-1. 修正 A — Collector (`otel/collector-xray.yaml` / `otel/collector-compose.yaml`)

`transform/peer-service-resolve` の最後 (`app_upstream` の後) に追加した。

```yaml
          # --- 呼び出し元ノードの補完 (親の無い CLIENT / PRODUCER / INTERNAL) ---
          - set(attributes["aws.local.service"], resource.attributes["service.name"]) where (kind == 1 or kind == 3 or kind == 4) and parent_span_id == SpanID(0x0000000000000000) and attributes["aws.span.kind"] == nil and resource.attributes["service.name"] != nil
          - set(attributes["aws.span.kind"], "LOCAL_ROOT") where (kind == 1 or kind == 3 or kind == 4) and parent_span_id == SpanID(0x0000000000000000) and attributes["aws.span.kind"] == nil and attributes["aws.local.service"] != nil
```

| 条件 | 意味 |
|---|---|
| `kind == 1 or 3 or 4` | INTERNAL / CLIENT / PRODUCER。SERVER はもともと自サービス名のセグメントになるので対象外 |
| `parent_span_id == SpanID(0x0000000000000000)` | 親が無い (= トレースの起点になっている) スパンだけ |
| `attributes["aws.span.kind"] == nil` | Application Signals を有効にしたエージェントが既に付けている場合は触らない |

awsxray exporter 側の動き (`MakeSegmentsFromSpan`):

| スパン | 印あり (LOCAL_ROOT) のときの出力 |
|---|---|
| CLIENT / PRODUCER | `aws.local.service` 名のセグメント **+** `peer.service` 名のサブセグメント (`namespace: remote`) |
| INTERNAL | `aws.local.service` 名のセグメント (スパン名 `ReportJob.run` などではなくサービス名になる) |

- サブセグメントは **元のスパン ID のまま** なので、EC2 側を計装していても親子は繋がる
- 親のあるスパン (通常の `/api/report` など) は条件から外れるので、出力は **一切変わらない**
- ブロックを新設せず既存の `transform/peer-service-resolve` に入れたのは、
  パイプラインの変更を不要にし、Compose / X-Ray の同一性検査
  (`scripts/check-collector-drift.sh`) にそのまま乗せるため
- Jaeger (ローカル) の表示は変わらない。Tags に `aws.span.kind=LOCAL_ROOT` が
  付くので、X-Ray で分割される対象のスパンをローカルで先に確認できる

### 4-2. 修正 B — ノード名 (`base/bin/otel-env.sh`)

既存の「ALB をどう見せるか」の分岐に 1 モード足しただけ。
判定エンジン (段0〜段4)・名前の検査・対応表の組み立ては既存のものをそのまま使う。

```sh
# 受け付ける値
    upstream|alb|both) ;;

# 帳票 EC2 (REPORT_ALB_HOST) に付ける名前
_alb_role_name="${PEER_NAME_EC2}"
[ "${APP_PEER_ALB_MODE}" = "alb" ] && _alb_role_name="${PEER_NAME_ALB}"
[ "${APP_PEER_ALB_MODE}" = "both" ] && _alb_role_name="${PEER_NAME_EC2}@${PEER_NAME_ALB}"   # ← 追加
```

| `APP_PEER_ALB_MODE` | ノード名 (既定値のとき) | 読み方 |
|---|---|---|
| `upstream` (既定・従来どおり) | `ec2_server` | EC2 |
| `alb` (従来どおり) | `report-alb` | ALB |
| **`both` (追加)** | **`ec2_server@report-alb`** | **report-alb の裏の ec2_server** |

区切りを `@` にした理由:

- X-Ray のセグメント名に使える記号 (使えるのは文字・数字・空白と `_ . : / % & # = + \ - @`)
- awsxray exporter 自身も DB を `<DB名>@<ホスト>` と名付けるので、X-Ray で見慣れた形
- 末尾が `-alb` になるので、Collector の `app_via=alb` 判定
  (`peer.service` が `-alb` で終わる) を **直さずに** そのまま使える
- `,` や `=` のように peer-service-mapping の対応表を壊す文字ではない

名前の部品は従来どおり `PEER_NAME_EC2` / `PEER_NAME_ALB` (6-1 節) で変えられる。

```sh
PEER_NAME_EC2=java-api-ec2  PEER_NAME_ALB=api-alb  →  java-api-ec2@api-alb
```

### 4-3. 本番での有効化 (`ecs/taskdef.template.json`)

front コンテナの環境変数に 1 行追加した (帳票 ALB の設定の直後)。

```json
{ "name": "APP_PEER_ALB_MODE", "value": "both" },
```

`otel-env.sh` の既定値は `upstream` のまま変えていない
(ローカルや既存ドキュメントの説明をそのまま保つため)。

---

## 5. 検証結果

### 5-1. X-Ray へ送られるセグメント (Collector を実際に動かして確認)

X-Ray API (`PutTraceSegments`) のモックを立て、Collector
(`otel/opentelemetry-collector-contrib:0.117.0` = ADOT v0.43.3 と同じ上流版の
awsxray exporter) に 3 種類のトレースを OTLP で投入し、実際に送られた
セグメントを比べた。設定は `otel/collector-xray.yaml` の修正前 / 修正後そのもので、
送信先だけを差し替えている。

**T2: 親の無い CLIENT スパン (今回の症状)**

| | 送られたもの | マップ |
|---|---|---|
| 修正前 | segment `ec2_server@report-alb` (parent なし) | `Client ──▶ ec2_server@report-alb` |
| 修正後 | segment `intra-api-front` (parent なし) + subsegment `ec2_server@report-alb` (parent = 左のセグメント, `namespace: remote`) | `Client ──▶ intra-api-front ──▶ ec2_server@report-alb` |

**T3: INTERNAL が起点 (スケジューラ等) → CLIENT**

| | 送られたもの |
|---|---|
| 修正前 | segment `ReportJob.run` → subsegment `ec2_server@report-alb` |
| 修正後 | segment **`intra-api-front`** → subsegment `ec2_server@report-alb` |

**T1: SERVER → CLIENT (通常の `/api/report`)**

修正前後で **完全に同じ** (segment `intra-api-front` → subsegment `ec2_server@report-alb`)。

### 5-2. その他

| 項目 | 結果 |
|---|---|
| `sh -n base/bin/otel-env.sh` | OK |
| `otel-env.sh --print` (`upstream` / `alb` / `both`) | それぞれ `ec2_server` / `report-alb` / `ec2_server@report-alb` |
| `APP_PEER_ALB_MODE=bogus` | ERROR で起動停止 (従来どおり) |
| `set -eu` 下で source (3 モード) | 途中で止まらない |
| `APP_PEER_NAME_MODE=xray-safe` + `PEER_NAME_EC2='帳票API（EC2）'` | `帳票API_EC2@api-alb` |
| `scripts/check-collector-drift.sh` | 全ブロック OK |
| `otelcol-contrib validate` (2 本) | OK |
| `ecs/taskdef.template.json` の JSON パース | OK |

---

## 6. 反映手順

### 本番 (ECS)

1. **9 章の前提を満たす** (`transform` プロセッサを含む Collector で動かす)
2. `otel/collector-xray.yaml` の内容で Secrets Manager の
   `AOT_CONFIG_CONTENT` を更新する
3. タスク定義を再生成・登録する (`scripts/gen-taskdefs.sh`)。
   front に `APP_PEER_ALB_MODE=both` が入る
4. **ベースイメージから再ビルドする** (`otel-env.sh` はベースイメージ
   `base/Containerfile` に焼き込まれており、front / back はそれを継承しているため)
5. 起動ログで確認する

```
[otel-env]   peer 判定 (ALB モード=both)
[otel-env]       REPORT_ALB_HOST=<report-alb>.<region>.elb.amazonaws.com -> ec2_server@report-alb (段: role)
```

> Java API サーバを呼ぶ URL が `REPORT_ALB_*` と別の ALB の場合は、
> その ALB の DNS 名を `REPORT_ALB_HOST` に入れれば同じ名前付けが効く
> (`REPORT_ALB_HOST` はノード名の対応付けにしか使わない)。
> 名前は `PEER_NAME_EC2` / `PEER_NAME_ALB` で変える。

### ローカル (Compose + Jaeger)

```sh
./scripts/build.sh                                   # otel-env.sh はベースイメージ側なので base から作り直す
APP_PEER_ALB_MODE=both docker compose up -d front back adot-collector
./scripts/smoke-trace.sh
```

Jaeger で `app_peer=ec2_server@report-alb` になっていること、
親の無い CLIENT スパンに `aws.span.kind=LOCAL_ROOT` が付いていることを確認する。
(Collector のイメージについては 9 章を参照)

---

## 7. まだ `Client` から線が出るときの切り分け

X-Ray コンソールでそのトレースを開き、`Client` の直後のセグメントの
**Raw data** を見る。

| `origin` / `name` | 何が起きているか | 対処 |
|---|---|---|
| `AWS::ECS::Container` / `ec2_server...` | front の親の無い CLIENT スパン (今回の修正対象) | 修正 A が効いていない。Collector の設定 (Secrets Manager) が更新されているか、`transform` を含む Collector で動いているかを確認 |
| `AWS::EC2::Instance` / EC2 側の `service.name` | **EC2 (Java API サーバ) 自身のセグメント** が、親の無い状態で届いている | 下の表 |

EC2 側を ADOT で計装している場合に、EC2 のセグメントに親が付かない主な原因:

| 原因 | 確認 / 対処 |
|---|---|
| front がトレースヘッダを送っていない (HTTP クライアントが計装対象外) | EC2 側のアクセスログで `traceparent` / `X-Amzn-Trace-Id` の `Parent=` を確認 |
| EC2 の `OTEL_PROPAGATORS` が front と違う | `xray,tracecontext,baggage` にそろえる |
| front は採らなかった (Sampled=0) のに EC2 が独自に採った | EC2 のサンプラを親に従う形 (`parentbased_*`) にする |
| ALB のヘルスチェックや他の呼び出し元 | 正常。front 由来ではない |

また EC2 を計装するときは、EC2 の `OTEL_SERVICE_NAME` を
**ノード名と同じ文字列 (`ec2_server@report-alb`)** にする
(既存の `docs/alb-tracing.md` 3 章の規則と同じ。`both` でも変わらない)。

---

## 8. 影響範囲と戻し方

### 影響範囲

- 修正 A は **親の無い** INTERNAL / CLIENT / PRODUCER スパンだけが対象。
  ALB 経由に限らず、スケジューラから Aurora / Valkey / SQS を呼んだ場合も
  `Client ──▶ intra-api-front ──▶ DataBase...` の形に揃う (意図した副次効果)
- 親のあるスパンは条件から外れるので出力は変わらない (5-1 の T1)
- 修正 B は `APP_PEER_ALB_MODE=both` を渡したコンテナだけ。既定は `upstream` のまま
- ノード名が `ec2_server` から `ec2_server@report-alb` に変わるので、
  X-Ray のフィルタ式やアラームで `ec2_server` を名指ししている箇所があれば直す
  (`annotation.app_peer = "ec2_server@report-alb"`)

### 戻し方

| 戻したいもの | 手順 |
|---|---|
| ノード名 | タスク定義の `APP_PEER_ALB_MODE` を `upstream` にする (再ビルド不要) |
| 線の起点 | Collector 2 本から追加した 2 行を消す |

---

## 9. ★ 前提の問題: ADOT Collector には `transform` プロセッサが無い

検証中に見つかった、**今回の修正より前からある** 問題。

リポジトリが固定している `public.ecr.aws/aws-observability/aws-otel-collector:v0.43.3`
に `otel/collector-xray.yaml` を (修正前のまま) 読ませると、起動時に止まる。

```
Error: failed to get config: cannot unmarshal the configuration: decoding failed due to the following error(s):
error decoding 'processors': unknown type: "transform" for id: "transform/peer-service-resolve"
(valid values: [tail_sampling resource batch groupbytrace span cumulativetodelta memory_limiter filter
metricstransform deltatorate k8sattributes attributes probabilistic_sampler resourcedetection metricsgeneration])
```

ADOT Collector の同梱コンポーネント (`pkg/defaultcomponents/defaults.go`) には、
v0.43.3 にも main にも `transformprocessor` が入っていない。
したがって既存の `transform/redact-sensitive` (秘匿情報の伏せ字) /
`transform/peer-service-resolve` / `transform/xray-annotations` も、
この版の ADOT では動かない。

- タスク定義ではサイドカーが `essential: false` なので、Collector が止まっても
  タスクは動き続け、**トレースだけが静かに欠ける**
- 現在 X-Ray にトレースが出ているなら、実環境の Collector は
  このリポジトリの設定・イメージとは別のもので動いている可能性が高い。
  その Collector に `transform` が無い場合、今回の修正 A は反映できない
  (修正 B はコンテナ側だけで効くので反映できる)

対処の候補 (今回は **変更していない**。どちらにするか決めてから直すこと):

| 案 | 内容 |
|---|---|
| 1 | サイドカーを上流の contrib ディストリビューション (`otel/opentelemetry-collector-contrib:0.117.0` など) にする。本構成が使う `awsxray` / `awsproxy` / `transform` / `filter` / `resourcedetection` / `health_check` はすべて含む。今回の検証もこのイメージで行った。ただし `--config=env:AOT_CONFIG_CONTENT` はそのまま使えるが、タスク定義の healthCheck (`/healthcheck`) は ADOT 固有のバイナリなので書き換えが要る |
| 2 | ADOT Collector のまま使い、`transform/*` に頼らない形に設定を作り直す (影響が大きい) |

変更箇所の候補: `ecs/taskdef.template.json` (サイドカーの image / healthCheck)、
`compose.yaml` の `ADOT_COLLECTOR_IMAGE` の既定値、`.env.example`。
