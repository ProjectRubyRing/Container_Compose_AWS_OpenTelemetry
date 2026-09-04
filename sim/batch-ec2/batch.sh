#!/bin/sh
# =============================================================================
#  sim/batch-ec2/batch.sh — 「EC2 バッチサーバ」のスタブ
#
#  ALB 経由でコンテナを定期的に呼ぶ。
#
#  ★ あえて計装していない
#    実運用のバッチサーバはシェルや古い Java で書かれていて計装できないことが多い。
#    その場合トレースの起点は「ALB が採番した X-Amzn-Trace-Id」になる。
#    つまり X-Ray 上では
#       (バッチサーバのノードは出ない) -> intra-api-front -> ...
#    という形になり、「誰が叩いたのか」がマップからは分からない。
#
#    そこで X-App-Caller: batch-ec2 を必ず付ける。コンテナ側は
#    otel-env.sh の capture-request-headers でこれをスパン属性に取り込み、
#    Collector が annotation app_caller に昇格させる。結果として X-Ray で
#        annotation.app_caller = "batch-ec2"
#    と検索すればバッチ由来のトレースだけを一覧できる。
#
#  ★ バッチサーバを計装する場合 (推奨)
#    バッチが Java なら、同じ ADOT Java Agent を入れるだけで
#    バッチ自身のノードがサービスマップに出るようになる。
#
#      export OTEL_SERVICE_NAME=batch-ec2
#      export OTEL_RESOURCE_ATTRIBUTES="service.namespace=<APP_NAMESPACE>,deployment.environment.name=<env>,app.service=batch,app.role=batch"
#      export OTEL_EXPORTER_OTLP_ENDPOINT=http://<ADOT Collector>:4317
#      export OTEL_PROPAGATORS=xray,tracecontext,baggage   # ★ コンテナ側と必ず揃える
#      java -javaagent:/opt/aws/aws-opentelemetry-agent.jar -jar batch.jar
#
#    EC2 に ADOT Collector を常駐させ、そこから X-Ray へ送る構成になる。
#    OTEL_PROPAGATORS がコンテナ側と食い違うと、ALB を挟んだ瞬間に
#    トレースが切れる。ここだけは必ず合わせること。
# =============================================================================
set -eu

ALB_URL="${ALB_URL:-http://alb:80}"
INTERVAL="${INTERVAL:-30}"
CALLER="${CALLER:-batch-ec2}"
PATHS="${PATHS:-/front/api/db /front/api/cache /back/api/db}"

echo "[batch] ALB_URL=${ALB_URL} interval=${INTERVAL}s caller=${CALLER}"
echo "[batch] paths: ${PATHS}"

# 起動直後は EAP がまだ上がっていないので少し待つ
sleep "${STARTUP_DELAY:-60}"

while true; do
    for p in ${PATHS}; do
        # -D - でレスポンスヘッダも出す。ALB が返した X-Amzn-Trace-Id を
        # ログに残しておくと、X-Ray 側で該当トレースを直接検索できる。
        code=$(curl -sS -o /dev/null -w '%{http_code}' \
                 --max-time 20 \
                 -H "X-App-Caller: ${CALLER}" \
                 "${ALB_URL}${p}" 2>/dev/null || echo "000")
        echo "[batch] $(date -u +%FT%TZ) GET ${p} -> ${code}"
    done
    sleep "${INTERVAL}"
done
