# X-Ray サービスマップのノード表示名 — 追加実装の解説

> このファイルは「**既存実装に対して何を足したか**」だけを説明する。
> 命名規約そのものは [`naming-convention.md`](naming-convention.md)、
> 経路ごとの仕組みは [`trace-paths.md`](trace-paths.md) を参照。

---

## 0. やりたかったこと

AWS X-Ray のサービスマップに出る**下流ノードの名前**を、運用で使う呼び名に変える。
**Java のコードは 1 行も変更しない**(自動計装のまま設定だけで実現する)。

| 相手 | 変更前のノード名 | ★ 変更後のノード名 |
|---|---|---|
| Aurora Serverless v2 (MySQL 8.4) | `aurora-mysql` | **`DataBase（Aurora_MySQL）`** |
| ElastiCache for Valkey | `elasticache-valkey` | **`session_store（Valkey）`** |
| 別 EC2 サーバ (帳票 EC2 / ALB 経由) | `report-ec2` | **`ec2_server`** |
| 外部 SLB | `external-slb` | `external-slb` (変更なし) |
| SQS | `sqs` | `sqs` (変更なし) |

---

## 1. 先に結論: 触るのはここだけ

```
base/bin/otel-env.sh   6-1 節  ← ★ ノード名の唯一の決定箇所
```

```sh
: "${PEER_NAME_AURORA:=DataBase（Aurora_MySQL）}"
: "${PEER_NAME_VALKEY:=session_store（Valkey）}"
: "${PEER_NAME_EC2:=ec2_server}"
: "${PEER_NAME_EXTERNAL_SLB:=external-slb}"
: "${PEER_NAME_SQS:=sqs}"
: "${PEER_NAME_BACKEND:=${APP_SERVICE}-back}"
```

`: "${VAR:=既定値}"` は「**VAR が未設定か空なら既定値を入れる**」という書き方。
つまり **compose / タスク定義から同名の環境変数を渡せば、この既定値を上書きできる**。
再ビルドは不要 (このシェルはイメージ内で起動のたびに評価される)。

---

## 2. なぜこれでノード名が変わるのか

### 2-1. X-Ray のノード名は 2 種類の出どころがある

| ノード | 名前の出どころ | 決める場所 |
|---|---|---|
| 自分たちのコンテナ (計装済み) | `service.name` | `otel-env.sh` 1 節 (`<APP_SERVICE>-<APP_ROLE>`) |
| **計装していない相手 (今回の対象)** | **クライアントスパンの `peer.service` 属性** | **`otel-env.sh` 6 節 (今回の追加箇所)** |

Aurora も Valkey も帳票 EC2 も、こちらからは「呼びに行く」だけで、相手は
OpenTelemetry を喋らない。したがって X-Ray はこちらのクライアントスパンから
相手の名前を推測するしかない。その推測結果が既定では接続先ホスト名になるため、
何もしないとマップに

```
aurora-prd.cluster-c9x8k2qz.ap-northeast-1.rds.amazonaws.com
```

のような FQDN がそのまま並ぶ。

### 2-2. `peer.service` はコードを触らずに付けられる

OpenTelemetry Java Agent には **peer-service-mapping** という機能がある。

```
otel.instrumentation.common.peer-service-mapping
  = <接続先ホスト>=<付けたい名前>,<接続先ホスト>=<付けたい名前>,...

環境変数名: OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING
```

エージェントが JDBC / Redis(Valkey) / HTTP クライアント / gRPC のスパンを作るとき、
接続先ホストがこの表に載っていれば `peer.service` 属性を付けてくれる。
**アプリのコードもライブラリも一切変更しない。**

`otel-env.sh` はこの対応表を「接続先ホストを持つ既存の環境変数」から自動生成する:

```sh
otel_peer_add "${DB_HOST:-}"           "${PEER_NAME_AURORA}"
otel_peer_add "${VALKEY_HOST:-}"       "${PEER_NAME_VALKEY}"
otel_peer_add "${REPORT_ALB_HOST:-}"   "${PEER_NAME_EC2}"
otel_peer_add "${EXTERNAL_SLB_HOST:-}" "${PEER_NAME_EXTERNAL_SLB}"
otel_peer_add "${SQS_HOST:-}"          "${PEER_NAME_SQS}"
```

左辺は**アプリが実際に接続に使っているホスト名の変数そのもの**なので、
「アプリの接続先」と「マッピングのキー」がずれることが構造的に起きない。

### 2-3. 実際に組み上がる値

```
OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING
  = aurora=DataBase（Aurora_MySQL）,valkey=session_store（Valkey）,alb=ec2_server,...
```

これを X-Ray の awsxray exporter が読み、**サブセグメント名 = サービスマップの
ノード名**として使う。

---

## 3. ★ 重要な注意: 丸括弧は X-Ray が受け付けない文字

### 3-1. 事実

AWS X-Ray のセグメント名 (= マップのノード名) に使えるのは、仕様上

```
Unicode の文字 / 数字 / 空白   と   _  .  :  /  %  &  #  =  +  \  -  @
```

だけで、**丸括弧 `(` `)` も全角括弧 `（` `）` も入っていない**
(日本語の文字は「Unicode の文字」なので使える)。

つまり今回指定された `DataBase（Aurora_MySQL）` と `session_store（Valkey）` は、
**X-Ray の仕様から外れた名前**である。ADOT Collector の版によって

- awsxray exporter が不正文字を落として送る → `DataBaseAurora_MySQL` のように括弧だけ消える
- そのまま送られ、X-Ray 側が受理しない → **そのノードがマップに出ない**

のどちらかになる。どちらに転んでも「狙った表示にならない」。

> **ローカルの Jaeger では括弧付きのまま正しく表示される。**
> Jaeger には X-Ray のような文字種制限が無いため、
> 「ローカルでは見えるのに X-Ray でだけ出ない」という形で表面化する。

### 3-2. だから `APP_PEER_NAME_MODE` を足した

指示どおりの名前を既定にしたうえで、**1 つの環境変数で挙動を切り替えられる**ようにした。

| `APP_PEER_NAME_MODE` | 挙動 | 送られる名前 | 使いどころ |
|---|---|---|---|
| **`as-is`** (既定) | 指定どおり送る。起動ログに WARN を出すだけ | `DataBase（Aurora_MySQL）` | まず実際の見え方を確認する。Jaeger はこれで OK |
| `xray-safe` | 使えない文字を `_` に置換して送る | `DataBase_Aurora_MySQL` | **X-Ray でノードが出なかったとき / 本番で確実に出したいとき** |
| `strict` | 使えない文字があればコンテナを起動させない | (起動しない) | 命名を規約で縛りたいとき |

as-is のままでも、起動ログに必ずこう出る:

```
[otel-env] WARN: PEER_NAME_AURORA: X-Ray のセグメント名に使えない文字が含まれています
  [DataBase（Aurora_MySQL）]。X-Ray 上では [DataBase_Aurora_MySQL] のように文字が
  落ちるか、ノード自体が出ない可能性があります。確実にノードを出したい場合は
  APP_PEER_NAME_MODE=xray-safe を指定してください (ローカルの Jaeger はこのままでも表示されます)。
```

**本番で X-Ray のマップに Aurora / Valkey のノードが出なかったら、まず
`APP_PEER_NAME_MODE=xray-safe` にする。**これ 1 つで解決する。
(タスク定義の環境変数を変えるだけ。イメージの再ビルドは不要)

### 3-3. 括弧を諦めずに読みやすくする案

X-Ray が受け付ける文字だけを使う場合の代替案:

```
DataBase_Aurora_MySQL        # xray-safe が自動でこうする
DataBase.Aurora_MySQL
DataBase-Aurora_MySQL
DataBase:Aurora_MySQL
DataBase Aurora_MySQL        # 空白も使える
```

例:

```sh
# .env (ローカル) / タスク定義 (ECS)
PEER_NAME_AURORA=DataBase.Aurora_MySQL
PEER_NAME_VALKEY=session_store.Valkey
```

---

## 4. 追加したもの一覧 (既存実装との差分)

### 4-1. `base/bin/otel-env.sh` — 6 節を 3 つに分割して書き直し

| 追加 | 内容 | なぜ |
|---|---|---|
| **6-1** | `PEER_NAME_*` 6 個の定義 | 名前をリテラルで埋め込まず変数にした。「どこを直せばノード名が変わるか」が 1 か所になる |
| **6-2** | 名前の検査 (`APP_PEER_NAME_MODE`) | 下記の 2 種類の文字を静かに事故らせないため |
| **6-3** | 対応表の組み立て (従来の処理) | リテラルが `PEER_NAME_*` 参照に変わっただけ |
| 9 節 | 起動ログにノード名の一覧を追加 | ECS では stdout だけが手掛かり。「今どの名前で送っているか」を必ず残す |

6-2 が止める / 警告する文字:

| 種類 | 例 | 挙動 |
|---|---|---|
| **`,` と `=`** | `a,b` / `a=b` | **必ず起動失敗** (終了コード 45) |
| X-Ray が使えない文字 | `（` `）` `(` `)` `[` `{` `!` `?` `*` `<` `>` `\|` `^` `~` `$` `;` `"` `'` `` ` `` `、` `。` | `APP_PEER_NAME_MODE` に従う (既定は WARN のみ) |
| 空文字 | `""` | **必ず起動失敗** (終了コード 45) |

> **なぜ `,` と `=` は問答無用で止めるのか**
> peer-service-mapping はこの 2 文字で対応表を区切る。名前に入ると表の解析がずれ、
> **その要素から後ろのマッピングが全部無効**になる。症状は「Aurora だけ名前が変」
> ではなく「**全部 FQDN に戻る**」という形で出るので、原因が極端に追いにくい。
> 起動時に止めた方が圧倒的に安い。

> **なぜ「使える文字」ではなく「使えない文字」を列挙したのか**
> `[[:alnum:]]` のような文字クラスで判定すると、ロケールが `C` のコンテナでは
> **日本語がすべて「不正」に化ける**。X-Ray は Unicode の文字を許可しているので
> それでは誤検知になる (`帳票EC2` のような正しい名前を弾いてしまう)。

> **なぜ検査結果を `$(...)` で受け取っていないのか**
> `$(...)` はサブシェル。その中で `otel_die` が `exit` してもサブシェルが
> 終わるだけで本体は走り続け、「規約違反なら起動させない」がまるごと効かなくなる。
> 結果は `_peer_name_out` 変数で受け渡している。

### 4-2. `otel/collector-xray.yaml` / `otel/collector-compose.yaml` — 保険を 2 行追加

`transform/xray-annotations` に、**両ファイルまったく同じ内容**で追加:

```yaml
- set(attributes["peer.service"], "DataBase（Aurora_MySQL）") where attributes["peer.service"] == nil and (attributes["db.system"] == "mysql" or attributes["db.system.name"] == "mysql")
- set(attributes["peer.service"], "session_store（Valkey）") where attributes["peer.service"] == nil and (attributes["db.system"] == "redis" or attributes["db.system.name"] == "redis" or attributes["db.system"] == "valkey" or attributes["db.system.name"] == "valkey")
```

**なぜ必要か。** peer-service-mapping は「**接続先ホスト名の完全一致**」でしか効かない。
次の場合に外れる:

- **Aurora / ElastiCache がクラスタ構成**で、クライアントが設定エンドポイントではなく
  **個別ノードの FQDN** へ繋いだとき
  (例: Valkey のクラスタモードで Jedis/Lettuce がノードを自動検出した場合。
  `VALKEY_HOST` は設定エンドポイントなので一致しない)
- `DB_HOST` / `VALKEY_HOST` の設定漏れ・綴り違い

外れると「**マップにノード数ぶんの FQDN ノードが増える**」という壊れ方をする。
そこで Collector 側で `db.system` を見て、最後にもう一度名前を寄せる。

- `peer.service` が既に入っているスパンには触らない (`== nil` 条件) ので、
  アプリ側のマッピングが効いている通常時は**何もしない**
- HTTP 経由の `ec2_server` には同じ保険を掛けていない。HTTP クライアントスパンからは
  「相手が EC2 かどうか」を属性だけでは判別できないため
  (`REPORT_ALB_HOST` のマッピングが唯一の手段)
- `db.system` は semconv 1.20 まで、`db.system.name` は 1.30 以降のキー名。
  エージェントの版が上がっても効くよう両方を見ている

> ★ この 2 行は 2 ファイルに同じ文字列で置く必要がある。
> ずれていないことは `./scripts/check-collector-drift.sh` が検査する
> (`transform/xray-annotations` ブロックを丸ごと比較している)。
> **ノード名を変えるときは、この 2 行も同時に直すこと。**

### 4-3. 設定の通り道

| ファイル | 追加内容 |
|---|---|
| `compose.yaml` | `PEER_NAME_*` / `APP_PEER_NAME_MODE` を `x-app-env` に追加。**値は書かず空で渡す** (既定値の置き場所を 2 か所にしないため)。`front` / `back` 両方に YAML アンカーで効く |
| `.env.example` | 上書き用の変数をコメントで一覧。`APP_PEER_NAME_MODE=as-is` |
| `ecs/taskdef.template.json` | `front` / `back` に `APP_PEER_NAME_MODE` と説明コメントを追加 |

### 4-4. 表示名を追随させただけのファイル

`docs/naming-convention.md` / `docs/trace-paths.md` / `README.md` /
`scripts/smoke-trace.sh` / 各 Collector 設定のヘッダコメント。

### 4-5. ★ 変更していないもの

**`sample-app/` の Java コードは 1 行も変更していない。**
これが今回の実装の要点で、ノード名は完全に「エージェント + 環境変数」だけで決まる。
実 WAR に差し替えても、そちらに手を入れる必要はない。

> `ApiResource.java` のレスポンス JSON に `"peer": "aurora-mysql"` のような文字列が
> 残っているが、これは検証用スタブが返す**ただの固定ラベル**で、トレースにも
> ノード名にも一切関係しない。

---

## 5. 動作確認

### 5-1. コンテナを起動せずに設定だけ確認する (いちばん速い)

```sh
APP_SERVICE=intra-api APP_ROLE=front APP_ENV=local APP_NAMESPACE=shopdemo \
DB_HOST=aurora VALKEY_HOST=valkey REPORT_ALB_HOST=alb OTEL_AGENT_ENABLED=false \
sh base/bin/otel-env.sh --print
```

```
[otel-env]   ノード表示名モード               = as-is
[otel-env]   X-Ray サービスマップの下流ノード名
[otel-env]       DB_HOST           -> DataBase（Aurora_MySQL）
[otel-env]       VALKEY_HOST       -> session_store（Valkey）
[otel-env]       REPORT_ALB_HOST   -> ec2_server
[otel-env]       EXTERNAL_SLB_HOST -> external-slb
[otel-env]       SQS_HOST          -> sqs
[otel-env]       BACKEND_HOST      -> intra-api-back (front のみ)
[otel-env]   peer-service-mapping             = aurora=DataBase（Aurora_MySQL）,valkey=session_store（Valkey）,alb=ec2_server
```

置換モードも同じ方法で確認できる:

```sh
APP_PEER_NAME_MODE=xray-safe   # -> DataBase_Aurora_MySQL / session_store_Valkey
APP_PEER_NAME_MODE=strict      # -> 終了コード 46 で停止
```

### 5-2. ローカル (Compose + Jaeger)

```sh
./scripts/up.sh
./scripts/smoke-trace.sh
```

- 起動ログ: `docker compose logs front | grep otel-env`
- Jaeger UI (http://localhost:16686) でトレースを開き、
  JDBC スパンの Tags に `peer.service` と `app_peer` が両方あり、値が
  `DataBase（Aurora_MySQL）` になっていること
- Jaeger の検索窓に `app_peer=DataBase（Aurora_MySQL）` で絞り込めること

Jaeger には X-Ray のようなサービスマップは無いので、**名前の確認まではできるが
「マップのノードとしてどう出るか」は確認できない**。そこは X-Ray で見る。

### 5-3. 本番 (ECS + X-Ray)

1. X-Ray コンソール → サービスマップ
2. `intra-api-back` から伸びる下流ノードの名前を見る
3. フィルタ式でも確認する

```
annotation.app_peer = "DataBase（Aurora_MySQL）"
```

**ノードが出ない / 名前から括弧が消えている場合は 3-2 の `xray-safe` に切り替える。**

Collector がセグメントを送れているかは ADOT サイドカーのログで分かる
(`telemetry.enabled: true` にしてある)。

---

## 6. ノード名を変えたいとき / 新しい相手を足したいとき

### 6-1. 既存ノードの名前を変える

**運用で変える場合** (再ビルド不要・推奨):

```sh
# .env (ローカル)
PEER_NAME_AURORA=DataBase.Aurora_MySQL

# タスク定義 (ECS)
{ "name": "PEER_NAME_AURORA", "value": "DataBase.Aurora_MySQL" }
```

**既定値そのものを変える場合**、次の 3 か所を**同時に**直す:

| # | 場所 | 内容 |
|---|---|---|
| 1 | `base/bin/otel-env.sh` 6-1 節 | `PEER_NAME_*` の既定値 (本体) |
| 2 | `otel/collector-xray.yaml` | `transform/xray-annotations` の保険 2 行 |
| 3 | `otel/collector-compose.yaml` | 同上 (**2 と完全に同じ文字列**) |

直したら必ず実行する:

```sh
./scripts/check-collector-drift.sh
```

2 と 3 がずれていれば `NG` で落ちる。

### 6-2. 新しい連携先を足す

**(a) 一時的・環境ごとに違う場合** — 既存のフックを使う。コード変更不要:

```sh
APP_EXTRA_PEER_SERVICE_MAPPING=search.internal=search_engine,mq.internal=message_broker
```

**(b) 恒久的に足す場合** — `otel-env.sh` の 6-1 / 6-2 / 6-3 に 1 行ずつ追加:

```sh
# 6-1
: "${PEER_NAME_SEARCH:=search_engine}"
# 6-2 の検査ループにも名前を足す
for _pn in PEER_NAME_AURORA ... PEER_NAME_SEARCH; do

# 6-3
otel_peer_add "${SEARCH_HOST:-}" "${PEER_NAME_SEARCH}"
```

---

## 7. うまくいかないときの切り分け

| 症状 | 原因 | 対処 |
|---|---|---|
| X-Ray にノードが出ない / 括弧が消えている | X-Ray が括弧を受け付けない (3 章) | `APP_PEER_NAME_MODE=xray-safe` |
| ノード名が FQDN のまま | `DB_HOST` 等とアプリの実際の接続先がずれている | 起動ログの `peer-service-mapping` と、スパンの `server.address` を突き合わせる |
| ノードが FQDN で複数に増えた | クラスタ構成で個別ノードへ接続している | Collector 側の保険が効く (4-2)。効いていなければ `db.system` が出ているか確認 |
| **全部**まとめて FQDN に戻った | 名前に `,` か `=` が入り対応表が壊れた | 起動しないはず (6-2 が止める)。起動しているなら古いイメージ |
| Jaeger では正しいが X-Ray だけ変 | ほぼ確実に文字種の問題 | 3 章 |
| Valkey のスパン自体が無い | `valkey-java` クライアントを使っている | Jedis / Lettuce に変える ([`trace-paths.md`](trace-paths.md) 経路 3) |
| コンテナが終了コード 45 / 46 で落ちる | 45 = `,` `=` / 空、46 = `strict` で不正文字 | 起動ログの `[otel-env] ERROR:` を読む |

---

## 8. EC2 が 2 種類ある件 (`ec2_server` の範囲)

| EC2 | 向き | マップでの見え方 |
|---|---|---|
| **帳票 EC2** (ALB 経由で呼びに行く) | コンテナ → EC2 | **`ec2_server` ノードとして出る** ← 今回の対象 |
| EC2 バッチ (ALB 経由で呼ばれる) | EC2 → コンテナ | **ノードとして出ない** |

EC2 バッチが出ないのは、**計装されていない発信元の存在を X-Ray が知りようがない**ため。
マップは `intra-api-front` から始まっているように見える。
こちらは `X-App-Caller` ヘッダ由来の annotation で辿る:

```
annotation.app_caller = "batch-ec2"
```

**EC2 バッチも計装してノードを出す場合**は、その JVM に同じ ADOT Java Agent を入れ、
`OTEL_SERVICE_NAME` を設定する。このときの名前には注意:

```sh
export OTEL_SERVICE_NAME=batch_ec2_server   # ★ ec2_server と別名にする
export OTEL_PROPAGATORS=xray,tracecontext,baggage
```

帳票 EC2 と同じ `ec2_server` にすると、**マップ上で 1 つのノードに合流してしまい、
「呼びに行く EC2」と「呼んでくる EC2」が区別できなくなる**。
(帳票 EC2 側を計装する場合は逆に、`peer.service` と `service.name` を
**同じ `ec2_server` に揃える**。揃えないとノードが 2 つに分裂する)
