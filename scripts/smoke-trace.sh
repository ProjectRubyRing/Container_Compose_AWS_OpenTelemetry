#!/bin/sh
# =============================================================================
#  scripts/smoke-trace.sh — 全通信経路を叩いてトレースを起こす
#
#    ./scripts/smoke-trace.sh            # 1 周
#    ./scripts/smoke-trace.sh 10         # 10 周
#
#  実行後、Jaeger UI (http://localhost:16686) で以下を確認する:
#    - Service に intra-api-front / intra-api-back が出ている
#    - Tags に app_service / app_role / app_caller / app_peer が入っている
#    - 1 トレースの中に mysql / redis / http / sqs のスパンが並んでいる
#
#  ★ どの経路を叩くと X-Ray のどのノードが埋まるかを対応させてある。
#    本番でサービスマップが埋まらないときは、同じ順で叩いて
#    どこで止まっているかを見る。
# =============================================================================
set -eu

FRONT="${FRONT_URL:-http://localhost:8080/front/api}"
ALB="${ALB_URL:-http://localhost:8081}"
ROUNDS="${1:-1}"

call() {
    # $1 = 説明 / $2 = メソッド / $3 = URL / $4 = X-App-Caller
    printf '  %-34s ' "$1"
    code=$(curl -sS -o /tmp/smoke-out.$$ -w '%{http_code}' \
             -X "$2" --max-time 30 \
             -H "X-App-Caller: ${4:-smoke-test}" \
             "$3" 2>/dev/null || echo "000")
    if [ "${code}" = "200" ]; then
        printf 'OK  (%s)\n' "$(head -c 120 /tmp/smoke-out.$$)"
    else
        printf 'NG  HTTP %s  %s\n' "${code}" "$(head -c 160 /tmp/smoke-out.$$ 2>/dev/null || true)"
    fi
    rm -f /tmp/smoke-out.$$
}

i=1
while [ "$i" -le "$ROUNDS" ]; do
    echo "===== round ${i}/${ROUNDS} ====="

    echo "-- 経路 2/3: front -> Aurora / Valkey --"
    call "front -> aurora-mysql"        GET  "${FRONT}/db"       user
    call "front -> elasticache-valkey"  GET  "${FRONT}/cache"    user

    echo "-- 経路 1: front -> back (タスク内) --"
    call "front -> back -> aurora"      GET  "${FRONT}/back"     user

    echo "-- 経路 4: front -> ALB -> 帳票EC2 --"
    call "front -> report-ec2"          GET  "${FRONT}/report"   user

    echo "-- 経路 7: front -> 外部SLB (VPC外) --"
    call "front -> external-slb"        GET  "${FRONT}/external" user

    echo "-- 経路 6: front -> SQS (この先 Lambda -> ALB -> back) --"
    call "front -> sqs"                 POST "${FRONT}/sqs"      user

    echo "-- 経路 5: EC2バッチ -> ALB -> コンテナ (ALB が X-Amzn-Trace-Id を採番) --"
    call "batch -> ALB -> front"        GET  "${ALB}/front/api/db"  batch-ec2
    call "batch -> ALB -> back"         GET  "${ALB}/back/api/db"    batch-ec2

    echo "-- まとめて (1 トレースに全経路) --"
    call "front -> all"                 GET  "${FRONT}/all"      user

    i=$((i + 1))
    [ "$i" -le "$ROUNDS" ] && sleep 2
done

cat <<'MSG'

=====================================================================
 確認のしかた
=====================================================================
 Jaeger UI : http://localhost:16686
   Service      = intra-api-front / intra-api-back
   Tags 検索例  = app_caller=batch-ec2
                  app_peer=aurora-mysql
                  app_role=back

 Collector が受信しているか:
   docker compose logs --tail=50 adot-collector

 Lambda(SQS) 経路が繋がっているか:
   docker compose logs --tail=30 lambda-runner
   -> "trace context found in message" が出ていれば段 1/2 は成功
   -> "WARN: メッセージにトレースコンテキストがありません" なら送信側の設定を確認

 ALB が X-Amzn-Trace-Id を採番しているか:
   docker compose logs --tail=30 alb
   -> trace=Root=1-........-........................ (generated) が出ていること
=====================================================================
MSG
