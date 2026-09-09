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
# 6. peer.service の多段階判定 — ★ X-Ray サービスマップの「下流ノード名」を作る
#
#    計装されていない相手 (Aurora / Valkey / 帳票 EC2 / 外部 SLB / ALB) は、
#    こちらのクライアントスパンから推測された名前でマップに出る。既定では
#      aurora-xxx.cluster-xxxxxxxx.ap-northeast-1.rds.amazonaws.com
#    のような FQDN がそのままノード名になり、マップが読めなくなる。
#
#    OpenTelemetry Java Agent の peer-service-mapping は
#    「接続先 -> 論理名」の対応表を環境変数だけで与えられる。アプリの
#    コードを 1 行も触らずにマップのノード名を運用上の呼び名へ揃えられる。
#
#      書式: <host>=<name>,<host>:<port>=<name>,<host>:<port>/<path>=<name>
#      対象: JDBC / Redis(Valkey) / HTTP クライアント / gRPC すべて
#      ★ host:port 形式は Java Agent 1.31.0 以降で使える。本構成が使う
#        ADOT 2.x は当然含む。ホスト名だけの照合しかできなかった頃の
#        制約 (下の「localhost 問題」) はこれで解消している。
#
#   ---------------------------------------------------------------------------
#   判定は 5 段。上の段で決まったらそこで打ち切る
#   ---------------------------------------------------------------------------
#     段0  明示     APP_PEER_SERVICE_MAPPING に運用が直接書いた対応
#     段1  役割     変数名から用途が確定しているもの (DB_HOST -> aurora-mysql)
#     段2  ドメイン ホスト名の部分一致 (.rds.amazonaws.com -> aurora-mysql)
#     段3  ポート   ポート番号 (3306 -> aurora-mysql)
#     段4  AWS 自動 *.<service>.amazonaws.com からサービス名を機械的に抜く
#     (どれも当たらなければマッピングを出さない = FQDN のまま出る)
#
#   段0/段1 は「この環境変数が何を指すか」を知っているので最も確度が高い。
#   段2 以降は用途が未知のホスト (運用中に足された連携先、AWS の別サービス、
#   マルチ AZ で FQDN が変わる相手) のための機械的な判定で、
#   **同じ順番・同じルールを ADOT Collector 側にも置いてある**
#   (otel/collector-*.yaml の transform/peer-service-resolve)。
#   エージェントが決められなかったスパンは Collector が同じ規則で決める。
#   どの段で決まったかは
#       - 起動ログ ([otel-env] peer-service サマリ)         … 段0〜4
#       - スパン属性 app_peer_src (annotation にも昇格)     … Collector 側
#   の 2 か所で確認できる。「なぜこのノード名になったのか」を追えるようにする
#   ためだけの仕組みなので、消してもトレース自体は壊れない。
#
#   ---------------------------------------------------------------------------
#   ALB をどう見せるか (APP_PEER_ALB_MODE)
#   ---------------------------------------------------------------------------
#     upstream (既定) ALB を透過扱いし、ALB の裏にいる実サービス名を使う。
#                     例: REPORT_ALB_HOST -> report-ec2
#                     マップは front -> report-ec2 の 1 エッジになる。
#     alb             ALB 自体をノードにする。例: -> report-alb
#                     マップは front -> report-alb で止まる。
#                     「どの ALB で詰まっているか」を見たいときはこちら。
#
#   ★ ALB は X-Ray にセグメントを送らない (API Gateway と違い、ALB 自身の
#     ノードは AWS 側からは作られない)。上のどちらを選んでも、マップに出る
#     ノードは「こちらのクライアントスパンが作った推定ノード」1 個だけで、
#     ALB とターゲットの内訳は分離できない。分離したいなら
#       (a) ターゲット (EC2) 側にも同じ ADOT Java Agent を入れる
#           = アプリ改修なし・自動計装だけで実サーバのノードが増える
#       (b) ALB アクセスログ (target_processing_time) と突き合わせる
#     の 2 通り。詳細と手順は docs/alb-tracing.md。
#     (a) を採るときは peer.service を EC2 側の OTEL_SERVICE_NAME と
#     **同じ文字列**にすること。違うと同じ相手が 2 ノードに割れる。
# -----------------------------------------------------------------------------
: "${APP_PEER_ALB_MODE:=upstream}"
case "${APP_PEER_ALB_MODE}" in
    upstream|alb) ;;
    *) otel_die "APP_PEER_ALB_MODE の値が不正です: [${APP_PEER_ALB_MODE}] / upstream または alb を指定してください。" 45 ;;
esac

# --- 段2 のルール: <ホスト名の部分文字列>=<論理名> ----------------------------
#   ホスト名に「含まれていれば」当たる。FQDN 全体を書かなくてよいので、
#   dev/stg/prd でエンドポイントが変わっても 1 行で追随できる。
#   前から順に評価し、最初に当たったものを採用する。
: "${APP_PEER_DOMAIN_RULES:=.rds.amazonaws.com=aurora-mysql,.cache.amazonaws.com=elasticache-valkey,.elb.amazonaws.com=alb,sqs.=sqs,.s3.=s3,s3.=s3,.execute-api.=api-gateway,.secretsmanager.=secretsmanager,.dkr.ecr.=ecr}"

# --- 段3 のルール: <ポート番号>=<論理名> --------------------------------------
#   ホスト名から何も分からない相手 (IP 直指定 / localhost / 社内 FQDN) 向け。
#   ★ ECS のタスク内は front も back も ADOT サイドカーも同じ localhost なので、
#     ポートでしか区別できない。ここが host:port 形式の一番の使いどころ。
: "${APP_PEER_PORT_RULES:=3306=aurora-mysql,6379=elasticache-valkey,4317=adot-collector,4318=adot-collector,2000=adot-awsproxy}"

# --- 段4: AWS 自動判定 --------------------------------------------------------
#   *.amazonaws.com のホスト名から AWS のサービス名トークンを機械的に抜く。
#     sqs.ap-northeast-1.amazonaws.com          -> sqs
#     bucket.s3.ap-northeast-1.amazonaws.com    -> s3
#     abc.ap-northeast-1.elb.amazonaws.com      -> elb
#   段2 のルールに載っていない AWS サービスを足したときに、FQDN が
#   そのままノード名になるのを防ぐための最後の受け皿。
: "${APP_PEER_AWS_AUTO:=true}"

# -----------------------------------------------------------------------------
#  ヘルパー
# -----------------------------------------------------------------------------

# URL からホストを取り出す (http://host:port/path -> host)
otel_url_host() {
    _u="${1#*://}"; _u="${_u%%/*}"; _u="${_u%%\?*}"
    case "${_u}" in *@*) _u="${_u##*@}" ;; esac
    case "${_u}" in
        \[*\]*) echo "${_u%%\]*}]" ;;   # IPv6 リテラル
        *:*)    echo "${_u%%:*}" ;;
        *)      echo "${_u}" ;;
    esac
    unset _u
}

# URL からポートを取り出す (省略時はスキームの既定値)
otel_url_port() {
    _s="${1%%://*}"; _u="${1#*://}"; _u="${_u%%/*}"; _u="${_u%%\?*}"
    case "${_u}" in *@*) _u="${_u##*@}" ;; esac
    case "${_u}" in
        \[*\]:*) echo "${_u##*\]:}" ; unset _s _u ; return 0 ;;
        \[*\])   : ;;
        *:*)     echo "${_u##*:}" ; unset _s _u ; return 0 ;;
    esac
    case "${_s}" in
        https|wss) echo 443 ;;
        http|ws)   echo 80 ;;
        *)         echo "" ;;
    esac
    unset _s _u
}

# 段2: ドメイン部分一致。当たれば論理名を stdout へ、外れれば 1 を返す。
otel_peer_by_domain() {
    [ -n "${1:-}" ] || return 1
    for _r in $(echo "${APP_PEER_DOMAIN_RULES}" | tr ',' ' '); do
        _frag="${_r%%=*}"; _name="${_r#*=}"
        [ -n "${_frag}" ] && [ "${_frag}" != "${_r}" ] || continue
        case "$1" in
            *"${_frag}"*) echo "${_name}"; unset _r _frag _name; return 0 ;;
        esac
    done
    unset _r _frag _name
    return 1
}

# 段3: ポート番号一致。
otel_peer_by_port() {
    [ -n "${1:-}" ] || return 1
    for _r in $(echo "${APP_PEER_PORT_RULES}" | tr ',' ' '); do
        _p="${_r%%=*}"; _name="${_r#*=}"
        [ -n "${_p}" ] && [ "${_p}" != "${_r}" ] || continue
        if [ "$1" = "${_p}" ]; then echo "${_name}"; unset _r _p _name; return 0; fi
    done
    unset _r _p _name
    return 1
}

# 段4: *.amazonaws.com からサービス名トークンを抜く。
#   最後の "amazonaws.com" を落とし、残りの末尾ラベルのうち
#   リージョン名 (ap-northeast-1 のような形) を読み飛ばした先を採る。
otel_peer_by_aws() {
    [ "${APP_PEER_AWS_AUTO}" = "true" ] || return 1
    case "${1:-}" in *.amazonaws.com) ;; *) return 1 ;; esac
    _rest="${1%.amazonaws.com}"
    while [ -n "${_rest}" ]; do
        _tok="${_rest##*.}"
        case "${_tok}" in
            # リージョン (ap-northeast-1 / us-east-2 ...) と汎用ラベルは読み飛ばす
            [a-z][a-z]-*-[0-9]|[a-z][a-z]-[a-z]*-[0-9]|api|vpce|cn|dualstack) ;;
            "") ;;
            *) echo "${_tok}"; unset _rest _tok; return 0 ;;
        esac
        case "${_rest}" in *.*) _rest="${_rest%.*}" ;; *) _rest="" ;; esac
    done
    unset _rest _tok
    return 1
}

# 多段階判定の本体。
#   $1 = ホスト / $2 = ポート (空可) / $3 = 段1 の役割既定名 (空可)
#   決まったら "<name> <stage>" を stdout へ、決まらなければ 1 を返す。
otel_peer_resolve() {
    _h="${1:-}"; _pt="${2:-}"; _role_default="${3:-}"
    [ -n "${_h}" ] || { unset _h _pt _role_default; return 1; }

    # 段0: 運用が名指しした対応 (host:port を優先し、無ければ host)
    for _r in $(echo "${APP_PEER_SERVICE_MAPPING:-}" | tr ',' ' '); do
        _k="${_r%%=*}"; _v="${_r#*=}"
        [ -n "${_k}" ] && [ "${_k}" != "${_r}" ] || continue
        if [ -n "${_pt}" ] && [ "${_k}" = "${_h}:${_pt}" ]; then
            echo "${_v} explicit"; unset _h _pt _role_default _r _k _v; return 0
        fi
        if [ "${_k}" = "${_h}" ]; then
            echo "${_v} explicit"; unset _h _pt _role_default _r _k _v; return 0
        fi
    done

    # 段1: 変数名から用途が確定しているもの
    if [ -n "${_role_default}" ]; then
        echo "${_role_default} role"; unset _h _pt _role_default _r _k _v; return 0
    fi

    # 段2: ドメイン部分一致
    if _n="$(otel_peer_by_domain "${_h}")"; then
        echo "${_n} domain"; unset _h _pt _role_default _n; return 0
    fi

    # 段3: ポート番号
    if [ -n "${_pt}" ] && _n="$(otel_peer_by_port "${_pt}")"; then
        echo "${_n} port"; unset _h _pt _role_default _n; return 0
    fi

    # 段4: AWS 自動判定
    if _n="$(otel_peer_by_aws "${_h}")"; then
        echo "${_n} aws"; unset _h _pt _role_default _n; return 0
    fi

    unset _h _pt _role_default _n
    return 1
}

# -----------------------------------------------------------------------------
#  判定を回してマッピング文字列を組み立てる
# -----------------------------------------------------------------------------
_peer=""
_peer_report=""

otel_peer_emit() {
    # $1 = host / $2 = port (空可) / $3 = name
    [ -n "${1:-}" ] && [ -n "${3:-}" ] || return 0
    # localhost / 127.0.0.1 はポート付きでしか出さない。
    #   ECS のタスク内では front も back も ADOT サイドカーも同じ localhost。
    #   ホスト名だけのエントリを出すと「自分自身」や Collector まで
    #   同じ論理名で塗ってしまう。
    case "$1" in
        localhost|127.0.0.1|::1|"[::1]")
            [ -n "${2:-}" ] || return 0
            _peer="${_peer}${_peer:+,}$1:$2=$3"
            return 0 ;;
    esac
    _peer="${_peer}${_peer:+,}$1=$3"
    # ポートが分かっているときは host:port 版も出す (より具体的な方が優先される)
    [ -n "${2:-}" ] && _peer="${_peer},$1:$2=$3"
    return 0
}

# 判定対象の表。 <ホスト変数>|<ポート変数>|<URL 変数>|<段1 の役割既定名>|<説明>
#   役割既定名を空にすると段2 以降 (ドメイン/ポート/AWS) だけで判定する。
#   ★ 外部 SLB (EXTERNAL_SLB_HOST) は APP_PEER_ALB_MODE の影響を受けない。
#     こちらは AWS の ALB ではなく相手側のロードバランサーで、その裏に
#     何が居るかは分からない。透過扱いにしようがないので常に
#     external-slb というノードで止まる。
_alb_role_name="report-ec2"
[ "${APP_PEER_ALB_MODE}" = "alb" ] && _alb_role_name="report-alb"

otel_peer_targets() {
    cat <<TARGETS
DB_HOST|DB_PORT||aurora-mysql|Aurora Serverless v2 (MySQL)
VALKEY_HOST|VALKEY_PORT||elasticache-valkey|ElastiCache for Valkey
REPORT_ALB_HOST|REPORT_ALB_PORT|REPORT_ALB_URL|${_alb_role_name}|帳票 EC2 (ALB 経由)
EXTERNAL_SLB_HOST|EXTERNAL_SLB_PORT|EXTERNAL_SLB_URL|external-slb|外部 SLB (VPC 外)
SQS_HOST|SQS_PORT|SQS_ENDPOINT|sqs|Amazon SQS
TARGETS
    # back へのマッピングは front のときだけ。back 自身は back を呼ばない。
    if [ "${APP_ROLE}" = "front" ]; then
        echo "BACKEND_HOST|BACKEND_PORT|BACKEND_URL|${APP_SERVICE}-back|同一タスク内の back"
    fi
}

_old_ifs="${IFS}"
IFS='
'
for _t in $(otel_peer_targets); do
    IFS='|' read -r _hv _pv _uv _rd _desc <<TARGETLINE
${_t}
TARGETLINE
    IFS="${_old_ifs}"

    eval "_h=\${${_hv}:-}"
    eval "_pt=\${${_pv}:-}"
    if [ -n "${_uv}" ]; then
        eval "_url=\${${_uv}:-}"
    else
        _url=""
    fi
    # ホストが直接与えられていなければ URL から拾う。
    # 起動ログにはどちらの変数から採ったかを出す (切り分けのため)。
    _src_var="${_hv}"
    if [ -z "${_h}" ] && [ -n "${_url}" ]; then
        _h="$(otel_url_host "${_url}")"
        _src_var="${_uv}"
    fi
    [ -n "${_pt}" ] || { [ -n "${_url}" ] && _pt="$(otel_url_port "${_url}")"; }

    if [ -n "${_h}" ]; then
        if _res="$(otel_peer_resolve "${_h}" "${_pt}" "${_rd}")"; then
            _name="${_res%% *}"; _stage="${_res##* }"
            otel_peer_emit "${_h}" "${_pt}" "${_name}"
            _peer_report="${_peer_report}${_peer_report:+;}${_src_var}=${_h}${_pt:+:${_pt}} -> ${_name} (段: ${_stage})"
        else
            _peer_report="${_peer_report}${_peer_report:+;}${_src_var}=${_h} -> (判定できず: FQDN のまま出ます)"
        fi
    fi
    IFS='
'
done
IFS="${_old_ifs}"

# --- 用途が未知の連携先 (段2 以降だけで判定させる) ----------------------------
#   書式: host または host:port のカンマ区切り。
#     APP_PEER_EXTRA_HOSTS="orders.internal.example.com:8443,10.0.3.21:9000"
#   「連携先が増えたが名前は AWS/ドメイン/ポートの規則で決めてよい」ときに使う。
for _e in $(echo "${APP_PEER_EXTRA_HOSTS:-}" | tr ',' ' '); do
    [ -n "${_e}" ] || continue
    case "${_e}" in
        \[*\]:*) _h="${_e%%\]:*}]"; _pt="${_e##*\]:}" ;;
        *:*)     _h="${_e%%:*}";    _pt="${_e##*:}" ;;
        *)       _h="${_e}";        _pt="" ;;
    esac
    if _res="$(otel_peer_resolve "${_h}" "${_pt}" "")"; then
        _name="${_res%% *}"; _stage="${_res##* }"
        otel_peer_emit "${_h}" "${_pt}" "${_name}"
        _peer_report="${_peer_report}${_peer_report:+;}${_h}${_pt:+:${_pt}} -> ${_name} (段: ${_stage})"
    else
        _peer_report="${_peer_report}${_peer_report:+;}${_h} -> (判定できず)"
    fi
done

# 生の対応表を最後に足すためのフック (書式は peer-service-mapping そのもの)
if [ -n "${APP_EXTRA_PEER_SERVICE_MAPPING:-}" ]; then
    _peer="${_peer}${_peer:+,}${APP_EXTRA_PEER_SERVICE_MAPPING}"
fi

if [ -n "${_peer}" ]; then
    OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING="${_peer}"
    export OTEL_INSTRUMENTATION_COMMON_PEER_SERVICE_MAPPING
fi

unset _t _hv _pv _uv _rd _desc _h _pt _url _res _name _stage _e _old_ifs \
      _src_var _alb_role_name

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

# =============================================================================
#  --- HTTP リクエスト/レスポンスの中身をスパンに載せる ---
#
#  ★ 自動計装だけでどこまで見えるのか (結論)
#
#    見える  | ヘッダ (リクエスト/レスポンス、サーバ/クライアント両方)
#            |   -> capture-request-headers / capture-response-headers
#            |      許可リストに書いた名前だけが属性になる
#    見える  | クエリ文字列そのもの (url.query / url.full)
#            |   -> 既定で付く。設定不要。ただし伏せ字にはならない (後述)
#    見える  | リクエストパラメータを名前ごとに個別の属性へ
#            |   -> servlet の capture-request-parameters
#            |      GET のクエリと POST の application/x-www-form-urlencoded を
#            |      両方拾う (ServletRequest#getParameterValues と同じ範囲)
#    見えない| リクエストボディ / レスポンスボディそのもの
#            |   -> JSON や XML のボディを属性に載せる機能は
#            |      OpenTelemetry / ADOT の自動計装には無い。
#            |      ボディはストリームであり、エージェントが読むと
#            |      アプリが読めなくなる (一度しか読めない) ため、
#            |      仕様として意図的に実装されていない。
#            |      どうしても要る場合の現実的な代替は docs/request-attributes.md。
#
#  ★ 属性名 (Collector / X-Ray / Jaeger で探すときのキー)
#      http.request.header.<小文字ヘッダ名>     文字列配列
#      http.response.header.<小文字ヘッダ名>    文字列配列
#      servlet.request.parameter.<小文字名>     文字列配列
#      url.path / url.query / url.full          文字列
#
#    ★ 配列であることが X-Ray では重要。X-Ray の annotation は
#      スカラー値しか受け付けないため、配列のままでは検索できる
#      annotation にならない (metadata には入る)。Collector 側の
#      transform で先頭要素へ潰してから annotation に昇格させている。
#
#  ★ 個人情報の扱い
#    ヘッダもパラメータも「許可リストに書いたものだけ」が載る方式なので、
#    既定では何も漏れない。逆に言えば、ここに何を書くかがそのまま
#    「X-Ray / Jaeger に何を保存するか」の判断になる。
#    認証情報を含むヘッダは下の拒否リストで機械的に弾く。
# =============================================================================

# --- 拒否リスト: 何があっても取り込まないヘッダ ------------------------------
#   許可リストに紛れ込んでも、ここで落としてから JVM へ渡す。
#   「うっかり Cookie を入れてしまい X-Ray に平文で保存され続ける」
#   という事故は取り返しがつかない (保存済みトレースは消せない)。
: "${APP_CAPTURE_HEADERS_DENY:=authorization,proxy-authorization,cookie,set-cookie,x-api-key,x-amz-security-token,x-amz-credential,x-csrf-token,x-xsrf-token}"

# 許可リストから拒否リストのヘッダを取り除く。除去したら理由を必ず出す。
otel_filter_headers() {
    # $1 = ラベル (ログ用) / $2 = カンマ区切りの許可リスト
    _fh_out=""
    for _fh in $(echo "$2" | tr ',' ' '); do
        [ -n "${_fh}" ] || continue
        # 大文字小文字は区別しない (エージェント側も小文字で正規化する)
        _fh_lc="$(echo "${_fh}" | tr 'A-Z' 'a-z')"
        _fh_denied=0
        for _fd in $(echo "${APP_CAPTURE_HEADERS_DENY}" | tr ',' ' '); do
            [ -n "${_fd}" ] || continue
            if [ "${_fh_lc}" = "$(echo "${_fd}" | tr 'A-Z' 'a-z')" ]; then _fh_denied=1; break; fi
        done
        if [ "${_fh_denied}" = "1" ]; then
            otel_warn "$1 のヘッダ [${_fh_lc}] は拒否リスト (APP_CAPTURE_HEADERS_DENY) にあるため取り込みません。認証情報がトレースに保存されるのを防ぐためです。どうしても必要なら APP_CAPTURE_HEADERS_DENY から外してください (推奨しません)。"
            continue
        fi
        _fh_out="${_fh_out}${_fh_out:+,}${_fh_lc}"
    done
    echo "${_fh_out}"
    unset _fh _fh_lc _fh_denied _fd _fh_out
}

# --- サーバ側 (自分が受けたリクエスト) ---------------------------------------
#  ★ ALB を挟むと「誰が叩いたのか」がアプリからは見えなくなる。
#    ALB が付けてくれるヘッダをそのまま属性にすれば、コードを触らずに
#    呼び出し元・実クライアント IP・入口のプロトコルまで X-Ray から追える。
#
#      x-app-caller        自前の呼び出し元識別 (batch-ec2 / lambda-sqs / user)
#      x-amzn-trace-id     ALB が採番したトレース ID。ログとの突き合わせに使う
#      x-forwarded-for     ALB の手前の実クライアント IP
#      x-forwarded-proto   利用者側が HTTPS だったか (ALB で TLS 終端するため)
#      x-forwarded-port    同上
#      host                Host ヘッダ。同じ ALB に複数ドメインを載せている場合の切り分け
#      user-agent          ブラウザかバッチかの裏取り
#      referer             画面遷移の追跡
#      content-type        ボディの形式 (ボディ自体は載らないが形式は分かる)
#      x-request-id        呼び出し元が採番した ID があれば
: "${APP_CAPTURE_REQUEST_HEADERS:=x-app-caller,x-amzn-trace-id,x-forwarded-for,x-forwarded-proto,x-forwarded-port,host,user-agent,referer,content-type,x-request-id}"
if [ -n "${APP_CAPTURE_REQUEST_HEADERS_EXTRA:-}" ]; then
    APP_CAPTURE_REQUEST_HEADERS="${APP_CAPTURE_REQUEST_HEADERS},${APP_CAPTURE_REQUEST_HEADERS_EXTRA}"
fi

#  レスポンス側。ALB の裏のどのサーバが応答したかを持ち帰れる場合がある。
#      content-type / content-length  応答の形
#      x-server-id / x-backend-server 相手が付けてくれるなら「実サーバ」が分かる
#                                     (ALB は付けない。ターゲット側の実装次第)
: "${APP_CAPTURE_RESPONSE_HEADERS:=content-type,content-length,x-server-id,x-backend-server}"
if [ -n "${APP_CAPTURE_RESPONSE_HEADERS_EXTRA:-}" ]; then
    APP_CAPTURE_RESPONSE_HEADERS="${APP_CAPTURE_RESPONSE_HEADERS},${APP_CAPTURE_RESPONSE_HEADERS_EXTRA}"
fi

# --- クライアント側 (自分が投げたリクエスト) ---------------------------------
#  ★ ALB 越しの呼び出しで最も効く設定。
#    「自分が送った X-Amzn-Trace-Id」と「ALB が返してきた X-Amzn-Trace-Id」を
#    両方スパンに残すと、ALB でトレース ID が張り替えられていないかを
#    X-Ray / Jaeger 上だけで判定できる (docs/alb-tracing.md)。
: "${APP_CAPTURE_CLIENT_REQUEST_HEADERS:=x-app-caller,x-amzn-trace-id,traceparent,host}"
: "${APP_CAPTURE_CLIENT_RESPONSE_HEADERS:=x-amzn-trace-id,x-server-id,x-backend-server,server,content-type}"
if [ -n "${APP_CAPTURE_CLIENT_REQUEST_HEADERS_EXTRA:-}" ]; then
    APP_CAPTURE_CLIENT_REQUEST_HEADERS="${APP_CAPTURE_CLIENT_REQUEST_HEADERS},${APP_CAPTURE_CLIENT_REQUEST_HEADERS_EXTRA}"
fi
if [ -n "${APP_CAPTURE_CLIENT_RESPONSE_HEADERS_EXTRA:-}" ]; then
    APP_CAPTURE_CLIENT_RESPONSE_HEADERS="${APP_CAPTURE_CLIENT_RESPONSE_HEADERS},${APP_CAPTURE_CLIENT_RESPONSE_HEADERS_EXTRA}"
fi

# 外から OTEL_* を直接渡された場合はそちらを尊重する (脱出口)。
: "${OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_REQUEST_HEADERS:=$(otel_filter_headers 'HTTP server request' "${APP_CAPTURE_REQUEST_HEADERS}")}"
: "${OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_RESPONSE_HEADERS:=$(otel_filter_headers 'HTTP server response' "${APP_CAPTURE_RESPONSE_HEADERS}")}"
: "${OTEL_INSTRUMENTATION_HTTP_CLIENT_CAPTURE_REQUEST_HEADERS:=$(otel_filter_headers 'HTTP client request' "${APP_CAPTURE_CLIENT_REQUEST_HEADERS}")}"
: "${OTEL_INSTRUMENTATION_HTTP_CLIENT_CAPTURE_RESPONSE_HEADERS:=$(otel_filter_headers 'HTTP client response' "${APP_CAPTURE_CLIENT_RESPONSE_HEADERS}")}"
export OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_REQUEST_HEADERS \
       OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_RESPONSE_HEADERS \
       OTEL_INSTRUMENTATION_HTTP_CLIENT_CAPTURE_REQUEST_HEADERS \
       OTEL_INSTRUMENTATION_HTTP_CLIENT_CAPTURE_RESPONSE_HEADERS

# --- リクエストパラメータ (クエリ + フォーム) --------------------------------
#
#  ★ 自動計装だけでリクエストパラメータを個別の属性にできる、唯一の口。
#
#    servlet 計装の capture-request-parameters に「名前」を並べると、
#    その名前のパラメータだけが
#        servlet.request.parameter.<小文字名>  (文字列配列)
#    としてサーバスパンに載る。中身は ServletRequest#getParameterValues と
#    同じなので、
#        - GET のクエリ文字列        ?orderId=A-1&mode=full
#        - POST の application/x-www-form-urlencoded ボディ
#    の両方が対象になる。JSON ボディ (application/json) は
#    サーブレットのパラメータではないので **取れない**。
#
#  ★ 既定は空 = 何も取り込まない。
#    業務パラメータは個人情報そのものであることが多く、X-Ray に保存された
#    トレースは後から消せない。「何を残してよいか」を決めた上で
#    名前を明示的に並べる運用にする。
#
#      APP_CAPTURE_REQUEST_PARAMETERS=orderid,mode,page
#
#  ★ POST のフォームを対象にするときの注意 (これは実装に効く)
#    エージェントはスパンを閉じる直前に getParameterValues を呼ぶ。
#    サーブレット仕様上、これはフォームボディをパースして消費する。
#    アプリが getInputStream() / getReader() で生ボディを読む作りだと、
#    先に消費されて読めなくなる可能性がある。
#    JAX-RS の @FormParam / @BeanParam のようにサーブレットの
#    パラメータ経由で読む作りなら問題ない。
#    生ボディを読むエンドポイントがあるなら、GET のクエリだけに絞るか
#    この機能自体を使わないこと。
#
#  ★ 設定キーの版差
#    ADOT 2.11 系 (本構成が固定している版) が解釈するのは
#      otel.instrumentation.servlet.experimental.capture-request-parameters
#    OpenTelemetry Java 2.2x 以降ではこれが
#      otel.instrumentation.servlet.experimental.request-parameters.included
#      otel.instrumentation.servlet.experimental.request-parameters.excluded
#    (ワイルドカード対応) に置き換わり、旧キーは非推奨エイリアスになった。
#    エージェントを上げたときに「設定したのに出ない / 非推奨 WARN が出る」で
#    詰まらないよう、どちらのキーを出すかを選べるようにしておく。
#      APP_CAPTURE_REQUEST_PARAMETERS_KEY=legacy (既定) | included
: "${APP_CAPTURE_REQUEST_PARAMETERS:=}"
: "${APP_CAPTURE_REQUEST_PARAMETERS_KEY:=legacy}"
if [ -n "${APP_CAPTURE_REQUEST_PARAMETERS}" ]; then
    case "${APP_CAPTURE_REQUEST_PARAMETERS_KEY}" in
        legacy)
            : "${OTEL_INSTRUMENTATION_SERVLET_EXPERIMENTAL_CAPTURE_REQUEST_PARAMETERS:=${APP_CAPTURE_REQUEST_PARAMETERS}}"
            export OTEL_INSTRUMENTATION_SERVLET_EXPERIMENTAL_CAPTURE_REQUEST_PARAMETERS
            ;;
        included)
            : "${OTEL_INSTRUMENTATION_SERVLET_EXPERIMENTAL_REQUEST_PARAMETERS_INCLUDED:=${APP_CAPTURE_REQUEST_PARAMETERS}}"
            export OTEL_INSTRUMENTATION_SERVLET_EXPERIMENTAL_REQUEST_PARAMETERS_INCLUDED
            if [ -n "${APP_CAPTURE_REQUEST_PARAMETERS_EXCLUDED:-}" ]; then
                : "${OTEL_INSTRUMENTATION_SERVLET_EXPERIMENTAL_REQUEST_PARAMETERS_EXCLUDED:=${APP_CAPTURE_REQUEST_PARAMETERS_EXCLUDED}}"
                export OTEL_INSTRUMENTATION_SERVLET_EXPERIMENTAL_REQUEST_PARAMETERS_EXCLUDED
            fi
            ;;
        *)
            otel_die "APP_CAPTURE_REQUEST_PARAMETERS_KEY の値が不正です: [${APP_CAPTURE_REQUEST_PARAMETERS_KEY}] / legacy または included を指定してください。" 46
            ;;
    esac
    otel_warn "リクエストパラメータをスパン属性に取り込みます: [${APP_CAPTURE_REQUEST_PARAMETERS}] / 個人情報を含む名前が混ざっていないか確認してください (保存済みトレースは後から消せません)。POST フォームを含む場合はアプリが生ボディを読んでいないことも確認してください。"
fi

# --- クエリ文字列の伏せ字 -----------------------------------------------------
#  url.query / url.full は既定で丸ごと属性に入る。トークンを URL に載せる
#  相手 (署名付き URL など) を呼ぶと、そのままトレースに保存される。
#
#  ★ エージェント側の伏せ字機能は OpenTelemetry Java 2.14.0 以降のもので、
#    本構成が固定している ADOT 2.11 系にはまだ入っていない。
#    したがって **Collector 側の transform/redact-sensitive が本命**
#    (otel/collector-*.yaml。両環境で同一)。ここでは、エージェントを
#    上げたときに二重で効くよう設定だけ先に置いておく。
#    キーが未知の版でも「知らないプロパティ」として無視されるだけで、
#    起動が壊れることはない。
: "${APP_SENSITIVE_QUERY_PARAMETERS:=AWSAccessKeyId,Signature,X-Amz-Signature,X-Amz-Credential,X-Amz-Security-Token,sig,X-Goog-Signature,token,access_token,id_token,refresh_token,password,passwd,secret,apikey,api_key}"
: "${OTEL_INSTRUMENTATION_SANITIZATION_URL_EXPERIMENTAL_SENSITIVE_QUERY_PARAMETERS:=${APP_SENSITIVE_QUERY_PARAMETERS}}"
export OTEL_INSTRUMENTATION_SANITIZATION_URL_EXPERIMENTAL_SENSITIVE_QUERY_PARAMETERS

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
    # ★ 「なぜこのノード名になったのか」を段まで含めて残す。
    #   X-Ray / Jaeger のマップが読めないときは、まずここを見る。
    otel_log "  peer 判定 (ALB モード=${APP_PEER_ALB_MODE})"
    if [ -n "${_peer_report}" ]; then
        _old="${IFS}"; IFS=';'
        for _line in ${_peer_report}; do
            IFS="${_old}"; otel_log "      ${_line}"; IFS=';'
        done
        IFS="${_old}"; unset _old _line
    else
        otel_log "      (対象なし)"
    fi
    otel_log "  capture request headers (server) = ${OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_REQUEST_HEADERS:-(なし)}"
    otel_log "  capture response headers(server) = ${OTEL_INSTRUMENTATION_HTTP_SERVER_CAPTURE_RESPONSE_HEADERS:-(なし)}"
    otel_log "  capture request headers (client) = ${OTEL_INSTRUMENTATION_HTTP_CLIENT_CAPTURE_REQUEST_HEADERS:-(なし)}"
    otel_log "  capture response headers(client) = ${OTEL_INSTRUMENTATION_HTTP_CLIENT_CAPTURE_RESPONSE_HEADERS:-(なし)}"
    otel_log "  capture request parameters       = ${APP_CAPTURE_REQUEST_PARAMETERS:-(なし。ボディは自動計装では取得不可)}"
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
