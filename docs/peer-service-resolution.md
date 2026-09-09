# 下流ノード名の多段階判定 (peer.service)

X-Ray のサービスマップ / Jaeger の相手先に並ぶ **オブジェクトの名前** を
どう決めているか。

---

## 0. 何を解決したいのか

計装されていない相手 (Aurora / Valkey / ALB / 帳票 EC2 / 外部 SLB / SQS) は、
こちらのクライアントスパンから推測された名前でマップに出る。
何も設定しないと接続先 FQDN がそのままノード名になる。

```
intra-api-back ──▶ aurora-prd.cluster-cxa1b2c3d4e5.ap-northeast-1.rds.amazonaws.com
               ──▶ cache-prd.a1b2c3.ng.0001.apne1.cache.amazonaws.com
               ──▶ report-prd-1234567890.ap-northeast-1.elb.amazonaws.com
```

これには 3 つ問題がある。

| 問題 | 具体例 |
|---|---|
| 読めない | ノード名が長すぎてマップ上で重なる |
| 環境ごとに別ノードになる | dev と prd で FQDN が違うので同じ相手が別物に見える |
| 検索できない | 「Aurora を呼んでいるスパン」を横断で探せない |

**判定を通すと次のようになる。**

```
intra-api-back ──▶ aurora-mysql
               ──▶ elasticache-valkey
               ──▶ report-ec2   (ALB モードが alb なら report-alb)
```

---

## 1. X-Ray はノード名をどう決めているか

`awsxray` exporter は CLIENT / PRODUCER / CONSUMER スパンのセグメント名
(= サービスマップのノード名) を **上から順に** 探す。

| 順 | 見る属性 | 備考 |
|---|---|---|
| 1 | `aws.remote.service` | Application Signals 用。本構成では使わない |
| 2 | **`peer.service`** | ★ 本構成が使うのはここ |
| 3 | `aws.service` | AWS SDK 計装 |
| 4 | `db.name` (`@` + ホスト) | JDBC |
| 5 | `rpc.service` | gRPC / AWS SDK |
| 6 | `http.host` | HTTP クライアント |
| 7 | `net.peer.name` | ← **何もしないとここに落ちる = FQDN** |
| 8 | スパン名 | |

つまり **`peer.service` を付けるだけでノード名を完全に制御できる。**
アプリのコードには 1 行も触らない。

> ★ Application Signals (`OTEL_AWS_APPLICATION_SIGNALS_ENABLED=true`) を
> 有効にすると `aws.remote.service` が付き、1 の方が優先される。
> その場合ここの `peer.service` は名前に効かなくなる。本構成は
> Application Signals を使わない前提で組んである。

Jaeger にはこの優先順位が無く、`peer.service` はただのタグとして出る。
それでも同じ値を入れておけば **ローカルで見た名前がそのまま本番の
ノード名になる** ので、検証がそのまま通用する。

---

## 2. 判定は 5 段

上の段で決まったらそこで打ち切る。

| 段 | 名前 | 誰が決めるか | 何を見るか |
|---|---|---|---|
| 0 | `explicit` | アプリ (`otel-env.sh`) | `APP_PEER_SERVICE_MAPPING` に運用が直接書いた対応 |
| 1 | `role` | アプリ (`otel-env.sh`) | `DB_HOST` などの **変数名**。用途が確定している |
| 2 | `domain` | アプリ + Collector | ホスト名の **部分一致** |
| 3 | `port` | アプリ + Collector | **ポート番号** |
| 4 | `aws` | アプリ + Collector | AWS の命名規則 / AWS SDK 計装の属性 |
| 5 | `host` | Collector | どれも当たらず接続先ホストをそのまま |

### なぜ段0/1 が段2 より先なのか

「`DB_HOST` という変数に入っている」という事実は、
「ホスト名に `.rds.` が含まれている」より強い根拠だから。

`DB_HOST` を EC2 上の MySQL (`mysql01.internal.example.com`) に向けても
`aurora-mysql` のままノード名が保たれる。ドメイン判定を先にすると、
この場合だけ名前が変わってマップ上で別ノードに割れる。

### 段2 以降が要る理由

段0/1 は「起動時に環境変数で分かっている接続先」しか扱えない。
実際にはそれ以外の相手が必ず出てくる。

- 運用中に足された連携先
- AWS SDK が内部で叩く別サービス (STS / Secrets Manager など)
- IP 直指定・動的に変わる FQDN
- Aurora のリーダーエンドポイント / フェイルオーバー後の別 FQDN

これらは **アプリの再起動を待たずに** Collector 側で名付けられる。

---

## 3. アプリ側と Collector 側の役割分担

```
  front / back (ADOT Java Agent)
    段0 明示 ─┐
    段1 役割 ─┤ otel-env.sh が peer-service-mapping を組み立てる
    段2 ドメイン ┤   -> スパンに peer.service が付いて出ていく
    段3 ポート ─┤
    段4 AWS 自動 ┘
                 │
                 ▼  OTLP
  ADOT Collector (transform/peer-service-resolve)
    peer.service が付いている  -> 触らない (app_peer_src=agent)
    付いていない               -> 段2 ドメイン
                                  段3 ポート
                                  段4 AWS 自動
                                  段5 ホストそのまま
                 │
                 ▼
        X-Ray サービスマップ / Jaeger
```

**同じ判定規則を 2 か所に置いている。**
片方だけ直すと「アプリを再起動するまでは Collector 版、
再起動後はエージェント版」という分かりにくいズレが出る。

| 直す場所 | ファイル |
|---|---|
| アプリ側 | `base/bin/otel-env.sh` の `APP_PEER_DOMAIN_RULES` / `APP_PEER_PORT_RULES` |
| Collector 側 | `otel/collector-xray.yaml` と `otel/collector-compose.yaml` の `transform/peer-service-resolve` |

Collector の 2 ファイルがずれていないかは
`./scripts/check-collector-drift.sh` が検査する (CI に入れること)。

---

## 4. 段ごとの設定

### 段0 — 名指し (最優先)

```sh
APP_PEER_SERVICE_MAPPING=10.0.5.9:9000=legacy-batch-api,10.0.5.10=legacy-batch-api
```

`host=名前` と `host:port=名前` のどちらでも書ける。
`host:port` の方が具体的なので優先される。

### 段1 — 変数名から

`otel-env.sh` が持っている表。ここは編集しなくても動く。

| 環境変数 | 既定の論理名 |
|---|---|
| `DB_HOST` | `aurora-mysql` |
| `VALKEY_HOST` | `elasticache-valkey` |
| `REPORT_ALB_HOST` (or `REPORT_ALB_URL`) | `report-ec2` / `report-alb` |
| `EXTERNAL_SLB_HOST` (or `EXTERNAL_SLB_URL`) | `external-slb` |
| `SQS_HOST` (or `SQS_ENDPOINT`) | `sqs` |
| `BACKEND_HOST` (or `BACKEND_URL`) ※front のみ | `<APP_SERVICE>-back` |

ホスト変数が空でも URL 変数があればそこからホストとポートを取り出す。

### 段2 — ドメイン部分一致

```sh
APP_PEER_DOMAIN_RULES=.rds.amazonaws.com=aurora-mysql,.cache.amazonaws.com=elasticache-valkey,.elb.amazonaws.com=alb,sqs.=sqs,.s3.=s3,s3.=s3,.execute-api.=api-gateway,.secretsmanager.=secretsmanager,.dkr.ecr.=ecr
```

**FQDN 全体ではなく「含まれていれば当たる」** 判定。
dev / stg / prd でエンドポイントが変わっても 1 行で追随できる。
前から順に評価し、最初に当たったものを使う。

### 段3 — ポート番号

```sh
APP_PEER_PORT_RULES=3306=aurora-mysql,6379=elasticache-valkey,4317=adot-collector,4318=adot-collector,2000=adot-awsproxy
```

★ **ECS のタスク内では、これが唯一の区別手段になる。**
awsvpc モードではタスク内の全コンテナが同じネットワーク名前空間を共有するので、
front から見ると back も ADOT サイドカーも同じ `localhost`。

```
localhost:18080 -> intra-api-back    (back)
localhost:4317  -> adot-collector    (OTLP)
localhost:2000  -> adot-awsproxy     (集中サンプリング)
```

> **以前はここが区別できなかった。**
> `peer-service-mapping` がホスト名だけで照合していた頃は
> 「`localhost` を `<service>-back` と呼ぶ」というマッピングしか書けず、
> ADOT サイドカーまで `back` と名乗ってしまう危険があった。
> Java Agent 1.31.0 以降は `host:port` 形式が使えるため、この制約は無い。
> `otel-env.sh` は `localhost` / `127.0.0.1` に対しては **ポート付きの
> エントリしか出さない** ようにしてある。

### 段4 — AWS 自動判定

アプリ側は `*.amazonaws.com` のホスト名からサービス名トークンを抜く。

```
sqs.ap-northeast-1.amazonaws.com        -> sqs
mybucket.s3.ap-northeast-1.amazonaws.com -> s3
kinesis.ap-northeast-1.amazonaws.com     -> kinesis
```

Collector 側はホスト名より確実な、AWS SDK 計装が付ける属性を見る。

| 属性 | 例 |
|---|---|
| `rpc.system` = `aws-api` のときの `rpc.service` | `Sqs` |
| `messaging.system` | `aws.sqs` |
| `db.system` | `mysql` / `redis` |

`APP_PEER_AWS_AUTO=false` でアプリ側の段4 を止められる。

### 段5 — 受け皿 (Collector のみ)

どれも当たらなければ接続先ホストをそのまま `peer.service` にし、
`app_peer_src=host` を付ける。

**これが「名前を付け損ねている相手」の一覧になる。**

```
X-Ray   annotation.app_peer_src = "host"
Jaeger  Tags に app_peer_src=host
```

で引けたスパンがあれば、その接続先を段2/3 のルールに足す。
マップを綺麗に保つための宿題リストとして使う。

---

## 5. 決まった名前をどこで確認するか

### 起動ログ (アプリ側の判定)

```sh
docker compose logs front | grep -A 8 "peer 判定"
```

```
[otel-env]   peer 判定 (ALB モード=upstream)
[otel-env]       DB_HOST=aurora:3306 -> aurora-mysql (段: role)
[otel-env]       VALKEY_HOST=valkey:6379 -> elasticache-valkey (段: role)
[otel-env]       REPORT_ALB_HOST=alb:80 -> report-ec2 (段: role)
[otel-env]       EXTERNAL_SLB_HOST=external-slb:80 -> external-slb (段: role)
[otel-env]       SQS_HOST=localstack:4566 -> sqs (段: role)
[otel-env]       BACKEND_HOST=back:18080 -> intra-api-back (段: role)
```

本番の FQDN を与えると段が変わるのが分かる。

```
[otel-env]       DB_HOST=aurora-prd.cluster-cxa1b2.ap-northeast-1.rds.amazonaws.com:3306 -> aurora-mysql (段: role)
[otel-env]       10.0.3.21:6379 -> elasticache-valkey (段: port)
[otel-env]       kinesis.ap-northeast-1.amazonaws.com -> kinesis (段: aws)
```

### スパン属性 (Collector 側の判定)

| 属性 | 意味 |
|---|---|
| `app_peer` | 決まったノード名 (= `peer.service`) |
| `app_peer_src` | どの段で決まったか (`agent`/`domain`/`port`/`aws`/`host`) |
| `app_peer_host` | 判定に使った接続先ホスト |
| `app_peer_port` | 判定に使ったポート |

X-Ray では `app_peer` / `app_peer_src` を `indexed_attributes` に入れてあるので
annotation として検索できる。

```
annotation.app_peer     = "aurora-mysql"
annotation.app_peer_src = "host"
```

Jaeger では Tags に同じ名前で出る。

```
app_peer=aurora-mysql
app_peer_src=host
```

**検索のやり方だけが違い、意味は同じ。**
Jaeger で引けないものは X-Ray でも引けない。

---

## 6. よくある詰まり方

| 症状 | 原因 | 直し方 |
|---|---|---|
| ノード名が FQDN のまま | どの段も当たっていない | `app_peer_src=host` で絞って接続先を特定し、段2/3 にルールを足す |
| ローカルでは論理名、X-Ray では FQDN | Collector 設定の片方だけ直した | `./scripts/check-collector-drift.sh` |
| 同じ相手が 2 ノードに割れる | 環境で `peer.service` の文字列が違う | 段1 の役割名に寄せる (FQDN 依存の段2 に頼らない) |
| ADOT サイドカーが `back` として出る | `localhost` をホスト名だけでマッピングした | ポート付きで書く (`localhost:18080=...`) |
| 名前を変えたのにマップが古いまま | X-Ray のマップは直近の時間範囲で作られる | 時間範囲を新しくする。古いノードはそのうち消える |
| ALB のノードが出ない | ALB は X-Ray にセグメントを送らない | 仕様。`docs/alb-tracing.md` を参照 |
