# 命名規約 — X-Ray から通信を追いやすくするための名前の付け方

X-Ray のサービスマップは **`service.name` をそのままノード名にする**。
つまり名前の付け方が、そのままマップの読みやすさになる。ここが揺れると
「同じコンテナが 2 ノードに分裂する」「どのサービスのコンテナか分からない」という
最も痛い壊れ方をする。

本構成では名前を人が入力するのをやめ、**4 つの入力から機械的に導出する**。
導出は `base/bin/otel-env.sh` の 1 か所だけで行う。

---

## 1. 入力と導出

タスク定義 / compose が与えるのは次の 4 つだけ。

| 変数 | 値 | 意味 |
|---|---|---|
| `APP_SERVICE` | `intra-api` / `intra-web` / `inter-api` / `sf-api` | ECS サービス名と**完全一致**させる |
| `APP_ROLE` | `front` / `back` | タスク内のコンテナ名 |
| `APP_ENV` | `local` / `dev` / `stg` / `prd` | 環境 |
| `APP_NAMESPACE` | 例: `shopdemo` | システム識別子 |

ここから導出される値:

```
service.name = ${APP_SERVICE}-${APP_ROLE}
```

`otel-env.sh` は `APP_SERVICE` が 4 つの許可値以外だと **起動を止める**。
壊れたトレースが X-Ray に出てから気づくより、コンテナが上がらない方が安い。

---

## 2. X-Ray サービスマップに並ぶノード

### 自分たち (計装済み)

| ECS サービス | コンテナ | `service.name` = マップ上のノード名 |
|---|---|---|
| intra-api | front | `intra-api-front` |
| intra-api | back  | `intra-api-back` |
| intra-web | front | `intra-web-front` |
| intra-web | back  | `intra-web-back` |
| inter-api | front | `inter-api-front` |
| inter-api | back  | `inter-api-back` |
| sf-api    | front | `sf-api-front` |
| sf-api    | back  | `sf-api-back` |

ECS サービス名 + コンテナ名をハイフンで繋いだだけなので、
マップ上のノードから ECS コンソールのどのサービス・どのコンテナかが一意に辿れる。

### 下流 (計装していない相手)

計装できない相手のノード名は、こちら側のクライアントスパンの `peer.service` で決まる。
`otel-env.sh` が接続先ホストの環境変数から `peer-service-mapping` を組み立てる。

| 相手 | ホストを与える環境変数 | マップ上のノード名 |
|---|---|---|
| Aurora Serverless v2 (MySQL 8.4) | `DB_HOST` | `aurora-mysql` |
| ElastiCache for Valkey | `VALKEY_HOST` | `elasticache-valkey` |
| 帳票 EC2 (ALB 経由) | `REPORT_ALB_HOST` | `report-ec2` |
| 外部 SLB (VPC 外) | `EXTERNAL_SLB_HOST` | `external-slb` |
| SQS | `SQS_HOST` | `sqs` |
| back (front から見て) | `BACKEND_HOST` | `${APP_SERVICE}-back` |

これが無いと、マップには
`aurora-xxx.cluster-abc123.ap-northeast-1.rds.amazonaws.com`
のような FQDN がそのままノード名として並び、読めなくなる。

**アプリが接続に使うホスト名と、マッピングのキーが同じ環境変数から来る**ので、
両者がずれることが構造的に起きない。逆に、アプリ側でホスト名をハードコードすると
マッピングが外れて FQDN 表示に戻るので注意。

---

## 3. X-Ray のフィルタ式で使える annotation

リソース属性は X-Ray では metadata 側に入り、**フィルタ式で検索できない**。
検索できるのは annotation だけ。そのため Collector の
`transform/xray-annotations` がリソース属性をスパン属性へ写し、
`awsxray.indexed_attributes` で annotation に昇格させている。

| annotation | 値の例 | 出どころ |
|---|---|---|
| `app_service` | `intra-api` | `APP_SERVICE` |
| `app_role` | `back` | `APP_ROLE` |
| `app_env` | `prd` | `APP_ENV` |
| `app_ns` | `shopdemo` | `APP_NAMESPACE` |
| `app_peer` | `aurora-mysql` | `peer.service` |
| `app_caller` | `batch-ec2` / `lambda-sqs` / `user` / `healthcheck` | `X-App-Caller` ヘッダ |
| `ecs_service` | `intra-api` | `aws.ecs.service.name` |
| `ecs_task_family` | `intra-api-prd` | ECS リソース検出 |

### X-Ray コンソールでの検索例

```
# sf-api の back だけ
annotation.app_service = "sf-api" AND annotation.app_role = "back"

# EC2 バッチ由来のトレースだけ
annotation.app_caller = "batch-ec2"

# Lambda(SQS) 起点で 3 秒以上かかったもの
annotation.app_caller = "lambda-sqs" AND duration > 3

# Aurora を呼んでいて失敗したスパン
annotation.app_peer = "aurora-mysql" AND fault

# 本番の intra-web 全体
annotation.app_env = "prd" AND annotation.app_service = "intra-web"
```

### annotation キーの命名についての注意

X-Ray の annotation キーには **`[A-Za-z0-9_]` しか使えない**。
`service.namespace` のようなドット付きのキーはエクスポータが `service_namespace` へ
自動置換する。置換後の名前を先に決めておかないと「コンソールで何と打てば検索できるのか」
が分からなくなるため、本構成では最初から `app_service` / `app_role` のような
フラットな名前を明示的に作っている。

---

## 4. Jaeger (Compose) でも同じ名前で見える

`transform/xray-annotations` はローカルの Collector 設定でも同じものを通している。
そのため Jaeger の Tags 欄にも `app_service` / `app_role` / `app_caller` / `app_peer` が並ぶ。

| | X-Ray | Jaeger |
|---|---|---|
| サービス名 | サービスマップのノード | 左上の Service ドロップダウン |
| バッチ由来を検索 | `annotation.app_caller = "batch-ec2"` | Tags 欄に `app_caller=batch-ec2` |
| Aurora 呼び出しを検索 | `annotation.app_peer = "aurora-mysql"` | Tags 欄に `app_peer=aurora-mysql` |

**検索の書き方だけが違い、名前と意味は完全に同じ**。
ローカルで確認した内容がそのまま X-Ray に持ち込める。

---

## 5. サービスを増やすとき

`intra-api / intra-web / inter-api / sf-api` 以外を追加する場合は、
次の 2 か所を**同時に**更新する。片方だけだとコンテナが起動しない
(それが意図した動作)。

1. `base/bin/otel-env.sh` の `case "${APP_SERVICE}" in` の許可リスト
2. 本ドキュメントの表

`front` / `back` 以外のロール (例: `batch`) を足す場合も同様に
`case "${APP_ROLE}" in` を更新する。
