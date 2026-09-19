# リクエストの中身をトレースに載せる (自動計装でどこまでできるか)

「ヘッダ・クエリ・パラメータ・ボディ」のうち、**アプリを 1 行も
書き換えずに** X-Ray / Jaeger へ出せるのはどれか。

---

## 0. 結論

| 対象 | 自動計装だけで出せるか | 使う設定 | 属性名 |
|---|---|---|---|
| リクエストヘッダ (サーバ) | **出せる** | `otel.instrumentation.http.server.capture-request-headers` | `http.request.header.<名前>` |
| レスポンスヘッダ (サーバ) | **出せる** | `...http.server.capture-response-headers` | `http.response.header.<名前>` |
| リクエストヘッダ (クライアント) | **出せる** | `...http.client.capture-request-headers` | `http.request.header.<名前>` |
| レスポンスヘッダ (クライアント) | **出せる** | `...http.client.capture-response-headers` | `http.response.header.<名前>` |
| クエリ文字列そのもの | **既定で出る** | 設定不要 | `url.query` / `url.full` |
| クエリのパラメータを名前ごとに | **出せる** | `otel.instrumentation.servlet.experimental.capture-request-parameters` | `servlet.request.parameter.<名前>` |
| POST フォーム (`x-www-form-urlencoded`) のパラメータ | **出せる** | 同上 | 同上 |
| リクエストボディ (JSON / XML / バイナリ) | **出せない** | — | — |
| レスポンスボディ | **出せない** | — | — |

本構成ではこれらを `base/bin/otel-env.sh` が `APP_CAPTURE_*` という
入力から組み立てる。タスク定義や compose に `OTEL_*` を直書きしない。

---

## 1. なぜボディだけ出せないのか

**機能が存在しない。** 設定の問題ではない。

HTTP のリクエストボディは *一度しか読めないストリーム* である。
エージェントが計装のためにボディを読むと、その後アプリが読めなくなる
(または全量をメモリにバッファする必要がある)。

- 全リクエストのボディをメモリに持つ = OOM とレイテンシの原因
- ボディは業務データそのもの = 個人情報がまるごとトレースに載る
- トレースのペイロードが数百倍に膨らむ = 送信料・保存料に直結

OpenTelemetry はこれを **意図的に実装していない**。
ADOT にも当然無い。「設定を探せばある」ものではないので、
探す時間を使わずに下の代替へ進むのが早い。

### ボディの中身がどうしても要るときの代替

| 手段 | アプリ改修 | 備考 |
|---|---|---|
| **必要な値をクエリ/フォームのパラメータへ出す** | 小 | 一番安い。下の 4. がそのまま使える |
| **必要な値をヘッダへ出す** (`X-Order-Id` など) | 小 | 呼び出し側だけの改修で済むことが多い |
| JAX-RS の `ContainerRequestFilter` で `Span.current().setAttribute()` | 中 | 自動計装ではなくなる。載せる項目を選べるのが利点 |
| アクセスログにボディを出し `trace_id` で突き合わせる | 中 | トレースにボディを載せずに済む。保管先を分けられる |
| API Gateway / ALB のアクセスログ | 無 | ボディそのものは残らない |

**トレースにボディを載せない方が良い場面の方が多い**ことも押さえておく。
X-Ray に記録されたセグメントは個別に削除できない (保持期間が切れるまで残る)。

---

## 2. ヘッダ

### 既定で取り込むもの

`otel-env.sh` の既定 (`APP_CAPTURE_REQUEST_HEADERS`)。
**ALB を挟むと分からなくなる情報**を埋めることを狙っている。

| ヘッダ | 何が分かるか |
|---|---|
| `x-app-caller` | 呼び出し元 (batch-ec2 / lambda-sqs / user / healthcheck) |
| `x-amzn-trace-id` | ALB が採番したトレース ID。ALB アクセスログとの結合キー |
| `x-forwarded-for` | ALB の手前の実クライアント IP |
| `x-forwarded-proto` | 利用者側が HTTPS だったか (ALB で TLS 終端するため中は常に http) |
| `x-forwarded-port` | 同上 |
| `host` | 受けたドメイン (1 つの ALB に複数ドメインを載せる構成で効く) |
| `user-agent` | ブラウザかバッチかの裏取り |
| `referer` | 画面遷移の追跡 |
| `content-type` | ボディの形式 (中身は載らないが形式は分かる) |
| `x-request-id` | 呼び出し元が採番した ID。アプリログとの結合キー |

クライアント側 (`APP_CAPTURE_CLIENT_*`) では、送った / 返ってきた
`x-amzn-trace-id` と、ターゲットが名乗る `x-server-id` を拾う。
用途は `docs/alb-tracing.md`。

### 足す

```sh
APP_CAPTURE_REQUEST_HEADERS_EXTRA=x-tenant-id,x-channel
APP_CAPTURE_CLIENT_RESPONSE_HEADERS_EXTRA=x-cache
```

既定を残したまま追加できる。全部入れ替えたいときは
`APP_CAPTURE_REQUEST_HEADERS` そのものを指定する。

### 取り込まないもの (拒否リスト)

```sh
APP_CAPTURE_HEADERS_DENY=authorization,proxy-authorization,cookie,set-cookie,x-api-key,x-amz-security-token,x-amz-credential,x-csrf-token,x-xsrf-token
```

許可リストに書いても **`otel-env.sh` が JVM へ渡す前に落とし、警告を出す。**
さらに Collector 側 (`transform/redact-sensitive`) でも同じ顔ぶれを
`delete_key` する。二重で止めているのは、
**一度 X-Ray に出た値は消せない**から。

```
[otel-env] WARN: HTTP server request のヘッダ [authorization] は拒否リスト
           (APP_CAPTURE_HEADERS_DENY) にあるため取り込みません。
```

### ★ ヘッダ属性は「文字列」ではなく「文字列の配列」

ヘッダは同名で複数回送れるため、計装は必ず配列で持つ。

```
http.request.header.x-app-caller = ["batch-ec2"]
```

これが 2 か所に効く。

1. **Collector の条件式で `==` を使うと一致しない。**
   エラーにもならず静かに素通りするので気づきにくい。
   `IsMatch()` は配列を文字列化してから照合するので当たる。
   (`filter/drop-healthcheck` はこの理由で `IsMatch` に直してある)
2. **X-Ray の annotation はスカラーしか受け付けない。**
   配列のままでは検索できる annotation にならず metadata 行きになる。
   `transform/xray-annotations` が `[0]` で先頭要素へ潰してから昇格させる。

昇格させているもの:

| 元のヘッダ | annotation |
|---|---|
| `x-app-caller` | `app_caller` |
| `x-forwarded-for` (先頭の IP だけ) | `client_ip` |
| `x-forwarded-proto` | `client_proto` |
| `host` | `http_host` |
| `x-request-id` | `request_id` |
| `x-amzn-trace-id` | `alb_trace_id` |
| レスポンスの `x-server-id` / `x-backend-server` | `app_upstream` |

---

## 3. クエリ文字列

`url.query` と `url.full` は **設定しなくても既定でスパンに付く。**
つまり「載せる」ではなく「載りすぎないようにする」のが仕事になる。

```
url.path  = /front/api/echo
url.query = orderId=A-1&mode=full&token=REDACTED
```

### 伏せ字は Collector が行う

`transform/redact-sensitive` が値だけを `REDACTED` に置換する
(キー名は残すので「何が渡ったか」は分かる)。

対象: `password` / `passwd` / `pwd` / `token` / `access_token` /
`id_token` / `refresh_token` / `secret` / `client_secret` / `apikey` /
`api_key` / `sig` / `signature` / `awsaccesskeyid` /
`x-amz-signature` / `x-amz-credential` / `x-amz-security-token` /
`x-goog-signature`

> ★ **エージェント側の伏せ字機能では足りない。**
> `otel.instrumentation.sanitization.url.experimental.sensitive-query-parameters`
> は OpenTelemetry Java **2.14.0 以降**の機能で、本構成が固定している
> ADOT **2.11 系にはまだ入っていない**。
> `otel-env.sh` はエージェントを上げたときに二重で効くよう設定だけ
> 先に置いてあるが、**いま実際に効いているのは Collector 側**。
> エージェントだけに任せて「効いているつもり」にならないこと。

署名付き URL を扱う相手を呼ぶ経路があるなら、ローカルで
`./scripts/smoke-trace.sh` を流し、Jaeger の `url.query` タグが
`token=REDACTED` になっていることを必ず目視すること。

---

## 4. リクエストパラメータ

**自動計装だけでパラメータを個別の属性にできる、唯一の口。**

```sh
APP_CAPTURE_REQUEST_PARAMETERS=orderid,mode
```

```
servlet.request.parameter.orderid = ["A-1"]
servlet.request.parameter.mode    = ["full"]
```

中身は `ServletRequest#getParameterValues()` と同じ範囲なので、

- GET のクエリ文字列 `?orderId=A-1&mode=full`
- POST の `application/x-www-form-urlencoded` ボディ

の **両方** が対象になる。`application/json` のボディはサーブレットの
パラメータではないので対象外 (= 出ない)。

### 既定は空

業務パラメータは個人情報そのものであることが多い。
**何を残してよいかを決めた上で名前を明示的に並べる**運用にしてある。
設定すると起動時に警告が出る (意図的)。

```
[otel-env] WARN: リクエストパラメータをスパン属性に取り込みます: [orderid,mode] /
           個人情報を含む名前が混ざっていないか確認してください
           (保存済みトレースは後から消せません)。
```

### ★ POST フォームを対象にするときの注意

エージェントは **スパンを閉じる直前に** `getParameterValues()` を呼ぶ
(リクエストのエンコーディングが確定した後に読むため)。
サーブレット仕様上、これはフォームボディをパースして消費する。

したがって、アプリが `getInputStream()` / `getReader()` で
**生ボディを読む作り**だと競合しうる。

| アプリの作り | 安全か |
|---|---|
| JAX-RS の `@FormParam` / `@BeanParam` | 安全 (パラメータ経由で読んでいる) |
| `HttpServletRequest#getParameter()` | 安全 |
| `getInputStream()` で生ボディを読む | **危険。GET のクエリだけに絞るか使わない** |

`sample-app` の `/api/echo` は前者で書いてあり、
生ボディを読んでいない (コメントで明示してある)。

### 設定キーの版差

| エージェント | キー |
|---|---|
| ADOT 2.11 系 (本構成の固定版) | `otel.instrumentation.servlet.experimental.capture-request-parameters` |
| OpenTelemetry Java 2.2x 以降 | `...servlet.experimental.request-parameters.included` / `.excluded` (ワイルドカード対応) |

新しい版では旧キーが **非推奨エイリアス**になり、使うと起動のたびに
deprecation WARN が出る。エージェントを上げたら切り替える。

```sh
APP_CAPTURE_REQUEST_PARAMETERS_KEY=included
APP_CAPTURE_REQUEST_PARAMETERS=user-*,order?
APP_CAPTURE_REQUEST_PARAMETERS_EXCLUDED=password,*-token
```

### X-Ray で検索したいとき

`servlet.request.parameter.orderid` は文字列配列なので、そのままでは
annotation にならない。`transform/xray-annotations` が 1 つだけを
`app_param` としてスカラーへ落として昇格させてある。

```
annotation.app_param = "A-1"
```

増やす場合は Collector 設定の該当 3 行を複製し、
`indexed_attributes` にも名前を足す (両ファイルとも)。
**個人情報を annotation にすると X-Ray の検索インデックスに残る。**
業務キー以外は昇格させないこと。

---

## 5. ローカルで確認する

```sh
docker compose up -d
./scripts/smoke-trace.sh
```

`smoke-trace.sh` が 3 つの POST/GET を投げる。
Jaeger UI (http://localhost:16686) で `intra-api-front` のトレースを開く。

| 叩いたもの | Tags で見えるべきもの |
|---|---|
| `GET /api/echo?orderId=A-1&mode=full&token=secret123` | `url.query` に `token=REDACTED`。`servlet.request.parameter.orderid` (設定時のみ) |
| `POST /api/echo` (form) | `servlet.request.parameter.orderid` (設定時のみ) |
| `POST /api/echo` (JSON) | ボディに関する属性が **何も無い** ことの確認 |

いずれのトレースでも `http.request.header.x-forwarded-for` などの
ヘッダ属性が配列で入っていること、`client_ip` などのスカラー版が
併存していることを見ておく。
**Jaeger の Tags で引けないものは X-Ray でも annotation にならない。**
