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
#  SQL のリテラルを ? に伏せる (既定 true)。個人情報が X-Ray に出るのを防ぐ。
: "${OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED:=true}"
export OTEL_INSTRUMENTATION_JDBC_DATASOURCE_ENABLED \
       OTEL_INSTRUMENTATION_COMMON_DB_STATEMENT_SANITIZER_ENABLED

# --- 呼び出し元の識別 ---
#  EC2 バッチ / Lambda / 利用者ブラウザのどれが入口かを X-Ray で絞り込めるよう、
#  独自ヘッダをスパン属性として取り込む。Collector 側で annotation app_caller へ
#  昇格させるので、X-Ray のフィルタ式で
#      annotation.app_caller = "batch-ec2"
#  のように検索できるようになる。
: "${OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_REQUEST_HEADERS:=x-app-caller}"
export OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_REQUEST_HEADERS

# --- エージェント自身のログ ---
#  JBoss は独自の LogManager を使う。エージェントが JUL を先に初期化すると
#  "The LogManager was not properly installed" が出ることがある。
#  simple は JUL を経由せず stderr へ直接書くため、その競合を避けられる。
: "${OTEL_JAVAAGENT_LOGGING:=simple}"
export OTEL_JAVAAGENT_LOGGING

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
    otel_log "  JBOSS_MODULES_SYSTEM_PKGS        = ${JBOSS_MODULES_SYSTEM_PKGS}"
    otel_log "  JAVA_OPTS_APPEND                 = ${JAVA_OPTS_APPEND:-(なし)}"
    otel_log "----------------------------------------------------------"
}

# 単体実行時 (sh otel-env.sh --print) は内容を表示して終わる。
# source されたときは何も出さず、呼び出し元が otel_print_summary を呼ぶ。
case "${1:-}" in
    --print) otel_print_summary ;;
esac
