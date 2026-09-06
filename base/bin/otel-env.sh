#!/bin/sh
# =============================================================================
#  base/bin/otel-env.sh
#
#   OpenTelemetry / ADOT 関連の環境変数を「1 か所で」組み立てる共通シェル。
#   jvm-env.sh から source される (単体確認は sh otel-env.sh --print)。
#
#   ---------------------------------------------------------------------------
#   このファイルが存在する理由
#   ---------------------------------------------------------------------------
#   OpenTelemetry の設定はほぼすべて環境変数で完結する。しかし
#   「タスク定義に OTEL_* を直書きする」運用にすると、
#       - サービスが 4 つ (intra-api / intra-web / inter-api / sf-api)
#       - コンテナが 2 つ (front / back)
#       - 環境が 4 つ (local / dev / stg / prd)
#   の掛け算 = 32 通りの環境変数セットができ、必ずどこかで命名が揺れる。
#   X-Ray のサービスマップはノード名 = service.name なので、命名が揺れると
#   「同じコンテナが別ノードとして 2 個並ぶ」という最悪の壊れ方をする。
#
#   そこで入力を次の 4 つだけに絞り、残りはすべてここで導出する。
#       APP_SERVICE    intra-api | intra-web | inter-api | sf-api  (= ECS サービス名)
#       APP_ROLE       front | back                                (= コンテナ名)
#       APP_ENV        local | dev | stg | prd
#       APP_NAMESPACE  システム識別子 (X-Ray の絞り込みに使う)
#
#   入力が規約から外れていたら「起動させない」。壊れたトレースを X-Ray に
#   出してから気づくより、コンテナが上がらない方が圧倒的に安い。
#
#   ---------------------------------------------------------------------------
#   命名規約 (詳細は docs/naming-convention.md)
#   ---------------------------------------------------------------------------
#       service.name = <APP_SERVICE>-<APP_ROLE>
#
#         intra-api  + front -> intra-api-front
#         intra-api  + back  -> intra-api-back
#         intra-web  + front -> intra-web-front
#         intra-web  + back  -> intra-web-back
#         inter-api  + front -> inter-api-front
#         inter-api  + back  -> inter-api-back
#         sf-api     + front -> sf-api-front
#         sf-api     + back  -> sf-api-back
#
#   X-Ray のサービスマップにはこの 8 ノードが並ぶ。ECS のサービス名と
#   コンテナ名をそのまま繋いだだけなので、マップ上のノードから
#   「どのサービスのどのコンテナか」が一意に辿れる。
# =============================================================================

# ※ 呼び出し元 (jvm-env.sh / entrypoint.sh) が set -e の下で source しても
#    途中で落ちないよう、致命的エラーは otel_die() 経由で明示的に exit する。

otel_log()  { echo "[otel-env] $*"; }
otel_warn() { echo "[otel-env] WARN: $*" >&2; }
otel_die()  { echo "[otel-env] ERROR: $1" >&2; exit "${2:-40}"; }

# -----------------------------------------------------------------------------
# 0. 入力 (この 4 つだけがタスク定義 / compose から与えられる)
# -----------------------------------------------------------------------------
: "${APP_SERVICE:=}"
: "${APP_ROLE:=}"
: "${APP_ENV:=local}"
: "${APP_NAMESPACE:=}"

# 規約違反を起動時に潰す。X-Ray のノードが増殖してから気づくのを防ぐ。
case "${APP_SERVICE}" in
    intra-api|intra-web|inter-api|sf-api) ;;
    "")
        otel_die "APP_SERVICE が未設定です。intra-api / intra-web / inter-api / sf-api のいずれかを、ECS サービス名と完全に一致させて指定してください。" 41
        ;;
    *)
        otel_die "APP_SERVICE が規約外です: [${APP_SERVICE}] / 許可値: intra-api, intra-web, inter-api, sf-api / サービスを増やす場合は base/bin/otel-env.sh の許可リストと docs/naming-convention.md を同時に更新してください。" 41
        ;;
esac

case "${APP_ROLE}" in
    front|back) ;;
    "")  otel_die "APP_ROLE が未設定です (front | back)。" 42 ;;
    *)   otel_die "APP_ROLE が規約外です: [${APP_ROLE}] (front | back)" 42 ;;
esac

case "${APP_ENV}" in
    local|dev|stg|prd) ;;
    *)   otel_warn "APP_ENV が想定外の値です: [${APP_ENV}] (local|dev|stg|prd)。そのまま使用します。" ;;
esac

[ -n "${APP_NAMESPACE}" ] || APP_NAMESPACE="unset-namespace"

# -----------------------------------------------------------------------------
# 1. service.name — X-Ray サービスマップのノード名そのもの
#
#    ここを環境変数で直接上書きさせない (= 外から OTEL_SERVICE_NAME を渡しても
#    無視する) のが本スクリプトの肝。上書きを許した瞬間に規約は崩れる。
#    検証用の脱出口としてのみ OTEL_SERVICE_NAME_FORCE を用意する。
#
#    【JBoss EAP 固有の注意】
#    OpenTelemetry Java Agent には「アプリケーションサーバのデプロイ名から
#    service.name を推測する」リゾルバがあり、JBoss/WildFly も対象になる。
#    OTEL_SERVICE_NAME を明示しないと WAR 名 (app.war -> app) が service.name に
#    なり、front も back も同じノードに潰れる。必ず明示すること。
# -----------------------------------------------------------------------------
OTEL_SERVICE_NAME="${APP_SERVICE}-${APP_ROLE}"
if [ -n "${OTEL_SERVICE_NAME_FORCE:-}" ]; then
    otel_warn "OTEL_SERVICE_NAME_FORCE により service.name を上書きします: ${OTEL_SERVICE_NAME_FORCE}"
    otel_warn "  -> 恒久運用では使わないこと。X-Ray サービスマップのノードが分裂します。"
    OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME_FORCE}"
fi
export OTEL_SERVICE_NAME

# -----------------------------------------------------------------------------
# 2. リソース属性
#
#    ここに入れた属性は「全スパン共通のメタデータ」になる。
#    X-Ray では既定でセグメントの metadata 側に入るため、そのままでは
#    フィルタ式で検索できない。検索可能な annotation へ昇格させるのは
#    Collector 側の transform + awsxray.indexed_attributes の仕事
#    (otel/collector-xray.yaml を参照)。
#
#    deployment.environment は semconv 1.27 で deployment.environment.name に
#    改称された。どちらのキーで運用されていても困らないよう当面は両方出す。
# -----------------------------------------------------------------------------
: "${APP_VERSION:=unknown}"

_res="service.namespace=${APP_NAMESPACE}"
_res="${_res},service.version=${APP_VERSION}"
_res="${_res},deployment.environment.name=${APP_ENV}"
_res="${_res},deployment.environment=${APP_ENV}"
# 独自属性。X-Ray の annotation では app_service / app_role に正規化される
# (X-Ray の annotation キーは [A-Za-z0-9_] のみ。ドットは _ に置換される)。
_res="${_res},app.service=${APP_SERVICE}"
_res="${_res},app.role=${APP_ROLE}"
# Collector の resourcedetection(ecs) は task/cluster は取れてもサービス名を
# 取りこぼすことがあるため、こちらから明示的に載せる。
_res="${_res},aws.ecs.service.name=${APP_SERVICE}"

# 呼び出し元が独自属性を足したい場合のフック (例: チーム名・課金タグ)
if [ -n "${APP_EXTRA_RESOURCE_ATTRIBUTES:-}" ]; then
    _res="${_res},${APP_EXTRA_RESOURCE_ATTRIBUTES}"
fi
OTEL_RESOURCE_ATTRIBUTES="${_res}"
export OTEL_RESOURCE_ATTRIBUTES

# -----------------------------------------------------------------------------
# 3. エクスポート先
#
#    ECS     : ADOT サイドカーはタスク内の別コンテナ = localhost で届く
#    Compose : コンテナごとにネットワーク名前空間が分かれるのでサービス名で解決
#
#    環境差はこの 1 変数だけ。compose.yaml 側で上書きする。
# -----------------------------------------------------------------------------
: "${OTEL_EXPORTER_OTLP_ENDPOINT:=http://localhost:4317}"
: "${OTEL_EXPORTER_OTLP_PROTOCOL:=grpc}"
export OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL

# トレースだけを出し、メトリクス/ログは CloudWatch Agent 側の担当にして
# 責務を分ける (ADOT_Collector_Sidecar_Generator と同じ方針)。
# 有効化する場合は OTEL_METRICS_EXPORTER=otlp を渡し、Collector 側に
# awsemf パイプラインを足すこと。
: "${OTEL_TRACES_EXPORTER:=otlp}"
: "${OTEL_METRICS_EXPORTER:=none}"
: "${OTEL_LOGS_EXPORTER:=none}"
export OTEL_TRACES_EXPORTER OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER

# エクスポータのタイムアウト。ADOT サイドカーの起動が遅れている間に
# アプリ側が長時間ブロックしないよう短めにしておく。
: "${OTEL_EXPORTER_OTLP_TIMEOUT:=10000}"
: "${OTEL_BSP_SCHEDULE_DELAY:=2000}"
: "${OTEL_BSP_MAX_EXPORT_BATCH_SIZE:=512}"
export OTEL_EXPORTER_OTLP_TIMEOUT OTEL_BSP_SCHEDULE_DELAY OTEL_BSP_MAX_EXPORT_BATCH_SIZE

# -----------------------------------------------------------------------------
# 4. 伝播 (propagator) — ★ X-Ray 構成で最も事故りやすい箇所
#
#    xray         : ALB / Lambda / AWS SDK が使う X-Amzn-Trace-Id ヘッダ
#    tracecontext : W3C traceparent (Java 同士、Compose ではこちらが主役)
#    baggage      : 付帯情報の伝播
#
#    【なぜ両方いるのか】
#      - EC2 バッチサーバや外部クライアントは計装されていない。その通信は
#        ALB が X-Amzn-Trace-Id を新規に付与して転送してくる。xray propagator が
#        無いと ALB が採番したトレース ID を拾えず、1 リクエストが複数トレースに割れる。
#      - Compose には ALB が居ないので X-Amzn-Trace-Id は誰も付けない。
#        tracecontext が無いと front -> back が繋がらない。
#
#    【順序の意味】
#      OpenTelemetry の複合 propagator は「リストの順に extract して後勝ち」。
#      xray,tracecontext とすると両方のヘッダが来た場合は traceparent が勝つ。
#      自前の Java 同士は traceparent を必ず送るので、
#      「AWS 由来のみ xray / 自前同士は W3C」という自然な使い分けになる。
#
#    【注意】上流の EC2 バッチや帳票 EC2 を後から計装する場合も必ず同じ
#      OTEL_PROPAGATORS を設定すること。片側だけ tracecontext だと ALB を
#      挟んだ瞬間にトレースが切れる。
# -----------------------------------------------------------------------------
: "${OTEL_PROPAGATORS:=xray,tracecontext,baggage}"
export OTEL_PROPAGATORS

# -----------------------------------------------------------------------------
# 5. サンプリング
#
#    local / dev : 全量 (parentbased_always_on)
#    stg / prd   : X-Ray 集中サンプリング (sampler=xray) を推奨。
#                  X-Ray コンソールのサンプリングルールで
#                  「/healthz は 0%」「通常は 5%」などを再デプロイ無しに変えられる。
#                  ルール取得は ADOT Collector の awsproxy 拡張 (:2000) 経由。
#
#    xray サンプラを使う場合は Collector 側で awsproxy を有効にすること
#    (otel/collector-xray.yaml に設定済み)。
# -----------------------------------------------------------------------------
if [ -z "${OTEL_TRACES_SAMPLER:-}" ]; then
    case "${APP_ENV}" in
        local|dev) OTEL_TRACES_SAMPLER="parentbased_always_on" ;;
        *)         OTEL_TRACES_SAMPLER="xray" ;;
    esac
fi
if [ "${OTEL_TRACES_SAMPLER}" = "xray" ] && [ -z "${OTEL_TRACES_SAMPLER_ARG:-}" ]; then
    # awsproxy 拡張の待受先。ECS ではサイドカーなので localhost。
    OTEL_TRACES_SAMPLER_ARG="endpoint=${OTEL_XRAY_PROXY_ENDPOINT:-http://localhost:2000}"
fi
export OTEL_TRACES_SAMPLER
# ※ [ ... ] && export ... と書くと、条件が偽のときこの行の終了ステータスが 1 になる。
#    本スクリプトは set -e 下の entrypoint.sh から source されるため、
#    シェルによってはそこで起動が止まる。if で明示的に書いておく。
if [ -n "${OTEL_TRACES_SAMPLER_ARG:-}" ]; then
    export OTEL_TRACES_SAMPLER_ARG
fi

# -----------------------------------------------------------------------------
# 6. peer.service マッピング — ★ X-Ray サービスマップの「下流ノード名」を作る
#
#    計装されていない相手 (Aurora / Valkey / 帳票 EC2 / 外部 SLB) は、
#    こちらのクライアントスパンから推測された名前でマップに出る。既定では
#      aurora-xxx.cluster-xxxxxxxx.ap-northeast-1.rds.amazonaws.com
#    のような FQDN がそのままノード名になり、マップが読めなくなる。
#
#    OpenTelemetry Java Agent の peer-service-mapping は
#    「接続先ホスト -> 論理名」の対応表を環境変数だけで与えられる。アプリの
#    コードを 1 行も触らずにマップのノード名を運用上の呼び名へ揃えられる。
#
#      書式: <host or ip>=<peer.service>,<host>=<peer.service>,...
#      対象: JDBC / Redis(Valkey) / HTTP クライアント / gRPC すべて
#
#    ここでは「接続先ホスト名を持つ環境変数」から自動生成する。ホスト名は
#    Compose と ECS で当然変わるが、この導出ロジックは変わらない。
# -----------------------------------------------------------------------------
otel_peer_add() {
    # $1 = ホスト (空なら何もしない) / $2 = 論理名
    [ -n "${1:-}" ] || return 0
    if [ -n "${_peer}" ]; then _peer="${_peer},$1=$2"; else _peer="$1=$2"; fi
}

_peer=""
otel_peer_add "${DB_HOST:-}"           "aurora-mysql"
otel_peer_add "${VALKEY_HOST:-}"       "elasticache-valkey"
otel_peer_add "${REPORT_ALB_HOST:-}"   "report-ec2"
otel_peer_add "${EXTERNAL_SLB_HOST:-}" "external-slb"
otel_peer_add "${SQS_HOST:-}"          "sqs"

# back へのマッピングは front のときだけ入れる。
#
# ★ 注意: peer-service-mapping はホスト名だけで照合し、ポートは見ない。
#   ECS のタスク内では front も back も ADOT サイドカーも同じ localhost なので、
#   back 自身にこのマッピングを入れると「自分自身を <service>-back と呼ぶ」
#   無意味なマッピングになる。front は実際に localhost:18080 (back) しか
#   呼ばないため、front に限れば正しく効く。
#   将来 localhost の別ポートを呼ぶ相手が増えたら、この方式では区別できない。
#   その場合は接続先を FQDN にするか、アプリ側で peer.service を明示する。
if [ "${APP_ROLE}" = "front" ]; then
    otel_peer_add "${BACKEND_HOST:-}" "${APP_SERVICE}-back"
fi

# 連携先が増えたときに外から足すためのフック
if [ -n "${APP_EXTRA_PEER_SERVICE_MAPPING:-}" ]; then
    if [ -n "${_peer}" ]; then _peer="${_peer},${APP_EXTRA_PEER_SERVICE_MAPPING}"
    else _peer="${APP_EXTRA_PEER_SERVICE_MAPPING}"; fi
fi
if [ -n "${_peer}" ]; then
    OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING="${_peer}"
    export OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING
fi

# -----------------------------------------------------------------------------
# 7. 計装ごとの調整
# -----------------------------------------------------------------------------

# --- SQS (front/back -> SQS -> Lambda -> ALB -> back) ---
#  既定の AWS SDK 計装は SQS メッセージ属性に W3C traceparent を入れる。
#  X-Ray 側と揃えるため、設定した propagator (xray を含む) をメッセージにも
#  使わせる。これで Lambda 側が X-Amzn-Trace-Id として取り出せる。
: "${OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_USE_PROPAGATOR_FOR_MESSAGING:=true}"
#  SQS スパンに queue 名などの補助属性を載せる
: "${OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_SPAN_ATTRIBUTES:=true}"
#  receive 側スパン (consumer) を出す。コンテナが直接ポーリングする経路を
#  足したときに効く。
: "${OTEL_INSTRUMENTATION_MESSAGING_EXPERIMENTAL_RECEIVE_TELEMETRY_ENABLED:=true}"
export OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_USE_PROPAGATOR_FOR_MESSAGING \
       OTEL_INSTRUMENTATION_AWS_SDK_EXPERIMENTAL_SPAN_ATTRIBUTES \
       OTEL_INSTRUMENTATION_MESSAGING_EXPERIMENTAL_RECEIVE_TELEMETRY_ENABLED

# --- JDBC (Aurora Serverless v2 / MySQL 8.4) ---
#  JBoss のデータソース (プール) から接続を取る所にもスパンを出す。
#  「SQL は速いのにプール枯渇で待たされている」を X-Ray 上で切り分けられる。
: "${OTEL_INSTRUMENTATION_JDBC_DATASOURCE_ENABLED:=true}"
export OTEL_INSTRUMENTATION_JDBC_DATASOURCE_ENABLED

#  SQL のリテラルを ? に伏せる (既定 true)。個人情報が X-Ray に出るのを防ぐ。
#
#  ★ 設定キーの新旧に注意 (WARN 対策 / 根本回避)
#    旧: otel.instrumentation.common.db-statement-sanitizer.enabled
#        (= OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED)
#    新: otel.instrumentation.common.db.query-sanitization.enabled
#        (= OTEL_INSTRUMENTATION_COMMON_DB_QUERY_SANITIZATION_ENABLED)
#
#    旧キーを設定していると、エージェントが起動のたびに
#
#      WARN io.opentelemetry.javaagent.shaded.instrumentation.api.incubator
#           .config.internal.DbConfig - The otel.instrumentation.common
#           .db-statement-sanitizer.enabled system property is deprecated and
#           will be removed in 3.0 Use otel.instrumentation.common
#           .db.query-sanitization.enabled instead
#
#    を出す。「旧キーが設定されている」ことが唯一の発火条件なので、
#    新キーへ移せば根本から消える。値の意味 (true = リテラルを伏せる) は同じ。
#
#    旧キーしか解釈しない古いエージェントに戻す場合でも、既定値が true の
#    ため「伏せられない」事故にはならない。明示的に無効化したいときだけ
#      APP_EXTRA_JAVA_OPTS="-Dotel.instrumentation.common.db-statement-sanitizer.enabled=false"
#    を渡すこと (この経路なら WARN も承知の上と分かる)。
if [ -n "${OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED:-}" ]; then
    otel_warn "OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED は非推奨キーです (ADOT/OTel 3.0 で削除)。OTEL_INSTRUMENTATION_COMMON_DB_QUERY_SANITIZATION_ENABLED へ読み替えて渡します。呼び出し側 (compose / タスク定義) の変数名を変更してください。"
    : "${OTEL_INSTRUMENTATION_COMMON_DB_QUERY_SANITIZATION_ENABLED:=${OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED}}"
    # ★ 旧キーは JVM へ渡さない。渡した時点で deprecation WARN が出る。
    unset OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED
fi
: "${OTEL_INSTRUMENTATION_COMMON_DB_QUERY_SANITIZATION_ENABLED:=true}"
export OTEL_INSTRUMENTATION_COMMON_DB_QUERY_SANITIZATION_ENABLED

# --- 呼び出し元の識別 ---
#  EC2 バッチ / Lambda / 利用者ブラウザのどれが入口かを X-Ray で絞り込めるよう、
#  独自ヘッダをスパン属性として取り込む。Collector 側で annotation app_caller へ
#  昇格させるので、X-Ray のフィルタ式で
#      annotation.app_caller = "batch-ec2"
#  のように検索できるようになる。
: "${OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_REQUEST_HEADERS:=x-app-caller}"
export OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_REQUEST_HEADERS

# --- AWS Service Events (関数レベル計装) ---
#
#  ★ WARN の根本回避 (設定値で消す)
#
#    ADOT Java Agent には AWS Service Events という「アプリの関数 (メソッド)
#    単位でイベントを出す」計装がある。この機能は
#        OTEL_AWS_SERVICE_EVENTS_FUNCTION_INSTRUMENT_ENABLED   有効/無効
#        OTEL_AWS_SERVICE_EVENT_PACKAGES_INCLUDE               対象パッケージ
#    の 2 つで制御するが、前者の既定が true / 後者の既定が空 のため、
#    何も設定しないと起動のたびに
#
#      WARN software.amazon.opentelemetry.javaagent.instrumentation
#           .serviceevents.config.ServiceEventConfig -
#           OTEL_AWS_SERVICE_EVENTS_FUNCTION_INSTRUMENT_ENABLED=true but
#           OTEL_AWS_SERVICE_EVENT_PACKAGES_INCLUDE is empty ?
#           no functions will be instrumented. Set PACKAGES_INCLUDE to opt in.
#
#    が出る。これは「有効なのに対象が 1 つも無い = 設定が矛盾している」
#    という警告なので、どちらかに寄せれば根本から消える。
#
#      (a) 使わない : ENABLED=false               … 本構成の既定
#      (b) 使う     : PACKAGES_INCLUDE を指定     … ENABLED は自動で true
#
#    (b) にする場合は APP_SERVICE_EVENT_PACKAGES へ対象パッケージを
#    カンマ区切りで渡す (例: APP_SERVICE_EVENT_PACKAGES=com.example.app)。
#    ★ 関数単位の計装はスパン数が一気に増える = X-Ray の課金に直結する。
#      パッケージは必ず絞ること。ワイルドカード的に com などを指定しない。
: "${OTEL_AWS_SERVICE_EVENT_PACKAGES_INCLUDE:=${APP_SERVICE_EVENT_PACKAGES:-}}"
if [ -n "${OTEL_AWS_SERVICE_EVENT_PACKAGES_INCLUDE}" ]; then
    : "${OTEL_AWS_SERVICE_EVENTS_FUNCTION_INSTRUMENT_ENABLED:=true}"
    export OTEL_AWS_SERVICE_EVENT_PACKAGES_INCLUDE
else
    : "${OTEL_AWS_SERVICE_EVENTS_FUNCTION_INSTRUMENT_ENABLED:=false}"
    # 空文字のまま渡すと「空を明示指定した」ことになり WARN の条件を満たす。
    unset OTEL_AWS_SERVICE_EVENT_PACKAGES_INCLUDE
fi
export OTEL_AWS_SERVICE_EVENTS_FUNCTION_INSTRUMENT_ENABLED

# 外から ENABLED=true だけを渡された場合 (= 矛盾したまま) は、こちらから
# 理由を示す。ADOT の WARN より前に出るので原因がすぐ分かる。
if [ "${OTEL_AWS_SERVICE_EVENTS_FUNCTION_INSTRUMENT_ENABLED}" = "true" ] \
   && [ -z "${OTEL_AWS_SERVICE_EVENT_PACKAGES_INCLUDE:-}" ]; then
    otel_warn "OTEL_AWS_SERVICE_EVENTS_FUNCTION_INSTRUMENT_ENABLED=true ですが対象パッケージが空です。関数計装は行われず、ADOT エージェントが起動時に WARN を出します。APP_SERVICE_EVENT_PACKAGES を指定するか、ENABLED を false にしてください。"
fi

# --- エージェント自身のログ ---
#  JBoss は独自の LogManager を使う。エージェントが JUL を先に初期化すると
#  "The LogManager was not properly installed" が出ることがある。
#  simple は JUL を経由せず stderr へ直接書くため、その競合を避けられる。
#
#  値: simple (既定) | application | none
#      none にするとエージェントのログが一切出なくなる。WARN は消えるが
#      エクスポート失敗などの ERROR まで消えるため、常用は勧めない。
: "${OTEL_JAVAAGENT_LOGGING:=simple}"
export OTEL_JAVAAGENT_LOGGING

# --- エージェントログの直接抑制 (カテゴリ単位) ---
#
#  ★ 「設定値での回避」とは別に、ログそのものを黙らせる手段も用意する。
#
#    エージェントのログは JBoss の logging サブシステムを通らない
#    (simple ロガーが stderr へ直接書く) ため、standalone.xml の
#    logger / filter-spec では止められない。止められるのは JVM の
#    システムプロパティだけ。
#
#    エージェント JAR は slf4j を io.opentelemetry.javaagent.slf4j へ
#    シェーディングして同梱している。したがって slf4j-simple の
#    設定プロパティも同じ接頭辞になる。
#
#      -Dio.opentelemetry.javaagent.slf4j.simpleLogger.log.<ロガー名>=<レベル>
#      -Dio.opentelemetry.javaagent.slf4j.simpleLogger.defaultLogLevel=<レベル>
#
#    <ロガー名> はドットを辿って上位に継承されるので、クラス単位でも
#    パッケージ単位でも指定できる。レベルは
#      trace | debug | info | warn | error | off
#    error にすると WARN 以下が消え、ERROR は残る (= 事故は見逃さない)。
#
#    書式: OTEL_AGENT_LOG_SUPPRESS_SPEC="<ロガー名>=<レベル>,<ロガー名>=<レベル>"
#          レベル省略時は error。抑制自体を止めるなら
#          OTEL_AGENT_LOG_SUPPRESS=false。
#
#    既定で黙らせている 2 件 (どちらも上流の設定値でも回避済み。こちらは
#    エージェントの版が上がって既定値が変わった場合などの二重の保険):
#      1. serviceevents          … PACKAGES_INCLUDE 空の WARN
#      2. ...config.internal.DbConfig … 非推奨キーの deprecation WARN
: "${OTEL_AGENT_LOG_SUPPRESS:=true}"
: "${OTEL_AGENT_LOG_SUPPRESS_SPEC:=software.amazon.opentelemetry.javaagent.instrumentation.serviceevents=error,io.opentelemetry.javaagent.shaded.instrumentation.api.incubator.config.internal.DbConfig=error}"

#    ★ SPEC を上書きすると上の 2 件が消える。既定を残したまま足したいときは
#      OTEL_AGENT_LOG_SUPPRESS_EXTRA を使う (書式は SPEC と同じ)。
: "${OTEL_AGENT_LOG_SUPPRESS_EXTRA:=}"

# --- トレース関連 WARN のグループ抑制 -----------------------------------------
#
#  ★ ロガー名を覚えなくても、原因の種類ごとに 1 語で止められるようにする。
#
#    トレースまわりの WARN は「出どころ」で性質がはっきり分かれる。
#    ロガー名を直接書かせると版が上がるたびに追随が必要になるので、
#    グループ名 -> ロガー名の対応をこのファイルが持ち、利用側は
#    OTEL_TRACE_WARN_SUPPRESS にグループ名を並べるだけにする。
#
#      グループ    止まる WARN                              既定
#      ----------- ---------------------------------------- ------
#      resource    EC2 / ECS / EKS のメタデータが引けない    ON
#                  (Compose には 169.254.170.2 が無いので
#                   毎起動必ず出る。取れなくてもトレースは
#                   出る = 資源属性が少し減るだけ)
#      context     Scope.close の呼び忘れ / Context 不整合   ON
#                  (EAP の非同期処理で出る。アプリ側では
#                   直せず、リクエストごとに繰り返し出る)
#      export      Collector へ送れない (接続拒否 / 5xx)     OFF
#                  ★ 既定で消さない。「X-Ray に出ない」の
#                    最初の手掛かりがこれ。起動直後だけの
#                    ノイズなら OTEL_WAIT_FOR_COLLECTOR=true
#                    (entrypoint.sh の 7.) で待ってから
#                    起動する方が筋がよい
#      sampler     X-Ray 集中サンプリングのルール取得失敗    OFF
#                  ★ 既定で消さない。サンプリングが既定値の
#                    ままになっている = 意図した比率で
#                    採れていない、という重要な事実
#      muzzle      計装の適用失敗 (muzzle / tooling)         OFF
#                  ★ 既定で消さない。特定の計装だけスパンが
#                    出ない原因がここに出る
#
#    値: グループ名のカンマ区切り / all (全グループ) / off (何もしない)
#    例: OTEL_TRACE_WARN_SUPPRESS=resource,context,export
#
#    ★ 消す前に「なぜ出ているか」を一度は読むこと。原因が分からない WARN を
#      消すと、後日の障害調査で最初の手掛かりを失う
#      (base/cli/31-logging-suppress-known-warnings.cli と同じ方針)。
: "${OTEL_TRACE_WARN_SUPPRESS:=resource,context}"

#    グループに適用するレベル。error = WARN 以下が消えて ERROR は残る。
#    off にすると ERROR まで消える (常用しないこと)。
: "${OTEL_TRACE_WARN_SUPPRESS_LEVEL:=error}"

#    ロガー名 (グループが持つもの / SPEC / EXTRA いずれも) について、
#    エージェント JAR 内での再配置後の名前も併せて設定するか。
#      false にすると書いた名前だけを設定する。
: "${OTEL_AGENT_LOG_SHADED_ALIAS:=true}"

#  グループ名 -> ロガー名 (空白区切り)。未知の名前なら 1 を返す。
otel_trace_warn_group_loggers() {
    case "$1" in
        resource)
            echo "io.opentelemetry.contrib.aws.resource io.opentelemetry.instrumentation.resources io.opentelemetry.sdk.autoconfigure.ResourceConfiguration" ;;
        context)
            echo "io.opentelemetry.context" ;;
        export)
            echo "io.opentelemetry.exporter io.opentelemetry.sdk.internal.ThrottlingLogger io.opentelemetry.sdk.trace.export" ;;
        sampler)
            echo "io.opentelemetry.contrib.awsxray" ;;
        muzzle)
            echo "io.opentelemetry.javaagent.tooling" ;;
        *)  return 1 ;;
    esac
}

#  エージェント JAR 内での再配置後 (シェーディング後) のロガー名を返す。
#
#  ★ OpenTelemetry Java Agent は同梱する SDK / API / 計装ライブラリを
#    別パッケージへ移してからシェーディングする。ロガー名 = クラスの
#    完全修飾名なので、公式ドキュメントに出てくる名前をそのまま書いても
#    実行時のロガー名とは一致しない。再配置の規則は 2 通り:
#
#      io.opentelemetry.instrumentation.**
#          -> io.opentelemetry.javaagent.shaded.instrumentation.**
#      io.opentelemetry.{api,context,sdk,exporter,contrib}.**
#          -> io.opentelemetry.javaagent.shaded.io.opentelemetry.**
#
#    (既定 SPEC の DbConfig が ...shaded.instrumentation.api... なのは前者)
#    io.opentelemetry.javaagent.** はエージェント自身のコードで移動しない。
#    software.amazon.** (ADOT 固有) も移動しない。
otel_shaded_alias() {
    case "$1" in
        io.opentelemetry.javaagent.*)
            echo "" ;;
        io.opentelemetry.instrumentation.*)
            echo "io.opentelemetry.javaagent.shaded.instrumentation.${1#io.opentelemetry.instrumentation.}" ;;
        io.opentelemetry.*)
            echo "io.opentelemetry.javaagent.shaded.$1" ;;
        *)
            echo "" ;;
    esac
}

#    ※ OTEL_JAVAAGENT_LOGGING=application のときはエージェントのログが
#      JBoss の logging サブシステムを通るため、この system property は効かない。
#      その場合は base/cli/31-logging-suppress-known-warnings.cli 側の
#      filter-spec に条件を足して止めること。
#  実際に流す抑制リストを組み立てる。
#    SPEC (既定 2 件 / 上書き可) + グループ展開 + EXTRA
_agent_log_suppress_spec="${OTEL_AGENT_LOG_SUPPRESS_SPEC}"
_trace_warn_groups=""

if [ -n "${OTEL_TRACE_WARN_SUPPRESS}" ] && [ "${OTEL_TRACE_WARN_SUPPRESS}" != "off" ]; then
    if [ "${OTEL_TRACE_WARN_SUPPRESS}" = "all" ]; then
        _tw_list="resource context export sampler muzzle"
    else
        _tw_list="$(echo "${OTEL_TRACE_WARN_SUPPRESS}" | tr ',' ' ')"
    fi
    for _tw_group in ${_tw_list}; do
        _tw_loggers="$(otel_trace_warn_group_loggers "${_tw_group}")" \
            || otel_die "OTEL_TRACE_WARN_SUPPRESS に未知のグループ名があります: [${_tw_group}] / 指定できるのは resource, context, export, sampler, muzzle, all, off です。個別のロガー名を止めたい場合は OTEL_AGENT_LOG_SUPPRESS_EXTRA を使ってください。" 44
        for _tw_logger in ${_tw_loggers}; do
            _agent_log_suppress_spec="${_agent_log_suppress_spec},${_tw_logger}=${OTEL_TRACE_WARN_SUPPRESS_LEVEL}"
        done
        _trace_warn_groups="${_trace_warn_groups}${_trace_warn_groups:+,}${_tw_group}"
    done
    unset _tw_list _tw_group _tw_loggers _tw_logger
else
    _trace_warn_groups="off"
fi

if [ -n "${OTEL_AGENT_LOG_SUPPRESS_EXTRA}" ]; then
    _agent_log_suppress_spec="${_agent_log_suppress_spec},${OTEL_AGENT_LOG_SUPPRESS_EXTRA}"
fi

_agent_log_suppress_state="off"
_agent_log_suppress_count=0
if [ "${OTEL_AGENT_LOG_SUPPRESS}" = "true" ]; then
    if [ "${OTEL_JAVAAGENT_LOGGING}" = "simple" ]; then
        # ロガー名・レベルに空白は入らないので、カンマを空白に変えて分割する。
        for _sup in $(echo "${_agent_log_suppress_spec}" | tr ',' ' '); do
            _sup_logger="${_sup%%=*}"
            _sup_level="${_sup#*=}"
            [ -n "${_sup_logger}" ] || continue
            [ "${_sup_level}" != "${_sup}" ] || _sup_level="error"
            JAVA_OPTS_APPEND="${JAVA_OPTS_APPEND:-} -Dio.opentelemetry.javaagent.slf4j.simpleLogger.log.${_sup_logger}=${_sup_level}"
            _agent_log_suppress_count=$((_agent_log_suppress_count + 1))
            # 再配置後の名前にも同じレベルを設定する (どちらで出ても止まる)。
            if [ "${OTEL_AGENT_LOG_SHADED_ALIAS}" = "true" ]; then
                _sup_alias="$(otel_shaded_alias "${_sup_logger}")"
                if [ -n "${_sup_alias}" ]; then
                    JAVA_OPTS_APPEND="${JAVA_OPTS_APPEND} -Dio.opentelemetry.javaagent.slf4j.simpleLogger.log.${_sup_alias}=${_sup_level}"
                    _agent_log_suppress_count=$((_agent_log_suppress_count + 1))
                fi
            fi
        done
        export JAVA_OPTS_APPEND
        unset _sup _sup_logger _sup_level _sup_alias
        _agent_log_suppress_state="on"
    else
        #  ★ application モードではエージェントのログが JBoss の logging
        #    サブシステムを通るため、この system property は一切効かない。
        #    その場合は base/cli/31-logging-suppress-known-warnings.cli の
        #    filter-spec 側で止めること。
        _agent_log_suppress_state="skipped (OTEL_JAVAAGENT_LOGGING=${OTEL_JAVAAGENT_LOGGING})"
        otel_warn "OTEL_JAVAAGENT_LOGGING=${OTEL_JAVAAGENT_LOGGING} のためエージェントログの抑制は効きません (simple のときだけ有効)。JBoss の logging サブシステム側 (31-logging-suppress-known-warnings.cli の filter-spec) で止めてください。"
    fi
fi

# エージェントのログ全体の下限。「WARN を一切見たくない」場合の最終手段。
#   OTEL_AGENT_LOG_LEVEL=error
# ※ 個別抑制で足りるうちは設定しないこと。設定した瞬間、まだ知らない
#   WARN (例: Collector へ繋がらない) まで見えなくなる。
if [ -n "${OTEL_AGENT_LOG_LEVEL:-}" ] && [ "${OTEL_JAVAAGENT_LOGGING}" = "simple" ]; then
    JAVA_OPTS_APPEND="${JAVA_OPTS_APPEND:-} -Dio.opentelemetry.javaagent.slf4j.simpleLogger.defaultLogLevel=${OTEL_AGENT_LOG_LEVEL}"
    export JAVA_OPTS_APPEND
fi

# -----------------------------------------------------------------------------
# 8. Java Agent の投入
#
#    ★ JAVA_TOOL_OPTIONS ではなく JAVA_OPTS_APPEND を使う。
#      JAVA_TOOL_OPTIONS は「そのコンテナで起動するすべての JVM」に効くため、
#      jboss-cli.sh を叩くたびにエージェントが起動し、
#        - CLI の起動が数秒遅くなる
#        - CLI 実行ぶんの無意味なスパンが X-Ray に出る
#        - CLI が Collector に繋がらず export エラーを吐き続ける
#      という副作用が出る。EAP 本体だけに効かせるのが正しい。
#
#    JBOSS_MODULES_SYSTEM_PKGS は standalone.conf が
#    -Djboss.modules.system.pkgs に変換する。JBoss Modules のクラスローダ
#    隔離からエージェントのパッケージを外さないと、計装対象クラスから
#    エージェントのクラスが見えず NoClassDefFoundError になる。必須。
# -----------------------------------------------------------------------------
: "${ADOT_AGENT_PATH:=/opt/aws/aws-opentelemetry-agent.jar}"
: "${OTEL_AGENT_ENABLED:=true}"

# EAP 既定値 (org.jboss.byteman) を消さないように連結する
_sys_pkgs="${JBOSS_MODULES_SYSTEM_PKGS:-org.jboss.byteman}"
case ",${_sys_pkgs}," in
    *,io.opentelemetry.javaagent,*) ;;
    *) _sys_pkgs="${_sys_pkgs},io.opentelemetry.javaagent" ;;
esac
JBOSS_MODULES_SYSTEM_PKGS="${_sys_pkgs}"
export JBOSS_MODULES_SYSTEM_PKGS

if [ "${OTEL_AGENT_ENABLED}" = "true" ]; then
    if [ -r "${ADOT_AGENT_PATH}" ]; then
        JAVA_OPTS_APPEND="${JAVA_OPTS_APPEND:-} -javaagent:${ADOT_AGENT_PATH}"
        export JAVA_OPTS_APPEND
    else
        otel_die "ADOT Java Agent が読めません: ${ADOT_AGENT_PATH} / イメージのビルドに失敗しているか実行ユーザに読み取り権がありません。計装なしで起動すると X-Ray に何も出ず原因が分かりにくいため、ここで停止します。意図的に無効化する場合は OTEL_AGENT_ENABLED=false を指定してください。" 43
    fi
else
    otel_warn "OTEL_AGENT_ENABLED=false: Java Agent を読み込みません (トレースは送信されません)"
fi

unset _res _peer _sys_pkgs

# -----------------------------------------------------------------------------
# 9. 起動ログ
#    ECS では stdout (awslogs) だけが手掛かりになる。「なぜ X-Ray に出ないのか」
#    を後から追えるよう、決定した値を必ず 1 か所にまとめて出す。
# -----------------------------------------------------------------------------
otel_print_summary() {
    otel_log "--------------- OpenTelemetry configuration ---------------"
    otel_log "  APP_SERVICE / APP_ROLE / APP_ENV = ${APP_SERVICE} / ${APP_ROLE} / ${APP_ENV}"
    otel_log "  OTEL_SERVICE_NAME                = ${OTEL_SERVICE_NAME}"
    otel_log "  OTEL_RESOURCE_ATTRIBUTES         = ${OTEL_RESOURCE_ATTRIBUTES}"
    otel_log "  OTEL_EXPORTER_OTLP_ENDPOINT      = ${OTEL_EXPORTER_OTLP_ENDPOINT} (${OTEL_EXPORTER_OTLP_PROTOCOL})"
    otel_log "  OTEL_TRACES_EXPORTER             = ${OTEL_TRACES_EXPORTER}"
    otel_log "  OTEL_PROPAGATORS                 = ${OTEL_PROPAGATORS}"
    otel_log "  OTEL_TRACES_SAMPLER              = ${OTEL_TRACES_SAMPLER} ${OTEL_TRACES_SAMPLER_ARG:-}"
    otel_log "  peer-service-mapping             = ${OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING:-(なし)}"
    otel_log "  service-events (function 計装)   = ${OTEL_AWS_SERVICE_EVENTS_FUNCTION_INSTRUMENT_ENABLED} packages=${OTEL_AWS_SERVICE_EVENT_PACKAGES_INCLUDE:-(なし)}"
    otel_log "  db query sanitization            = ${OTEL_INSTRUMENTATION_COMMON_DB_QUERY_SANITIZATION_ENABLED}"
    otel_log "  agent log suppress               = ${_agent_log_suppress_state} (-D ${_agent_log_suppress_count} 件)"
    otel_log "  trace WARN suppress (group)      = ${_trace_warn_groups} [level=${OTEL_TRACE_WARN_SUPPRESS_LEVEL}]"
    otel_log "  suppressed loggers               = ${_agent_log_suppress_spec}"
    otel_log "  JBOSS_MODULES_SYSTEM_PKGS        = ${JBOSS_MODULES_SYSTEM_PKGS}"
    otel_log "  JAVA_OPTS_APPEND                 = ${JAVA_OPTS_APPEND:-(なし)}"
    otel_log "----------------------------------------------------------"
}

# 単体実行時 (sh otel-env.sh --print) は内容を表示して終わる。
# source されたときは何も出さず、呼び出し元が otel_print_summary を呼ぶ。
case "${1:-}" in
    --print) otel_print_summary ;;
esac
