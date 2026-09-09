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
#    - X-Ray の indexed_attributes と同じ 6 つが引ける
#        app_ns / app_env / app_role / ecs_cluster / ecs_service / ecs_task_family
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

    echo "-- リクエストの中身がどこまでスパンに載るか --"
    #  ★ token= を混ぜてあるのは、Collector の transform/redact-sensitive が
    #    値を伏せるところまで確認するため。Jaeger の url.query タグが
    #      orderId=A-1&mode=full&token=REDACTED
    #    になっていれば効いている。生の token が見えたら設定が抜けている。
    call "クエリ (url.query / パラメータ)" GET "${FRONT}/echo?orderId=A-1&mode=full&token=secret123" user
    #  フォーム (application/x-www-form-urlencoded) はパラメータとして載る
    printf '  %-34s ' "フォーム (パラメータとして載る)"
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
             -X POST -H "X-App-Caller: user" \
             -H "Content-Type: application/x-www-form-urlencoded" \
             --data 'orderId=B-2&mode=quick' "${FRONT}/echo" 2>/dev/null || echo "000")
    printf '%s\n' "$([ "${code}" = "200" ] && echo OK || echo "NG HTTP ${code}")"
    #  JSON ボディは ★載らない★ (自動計装に機能が無い)。その確認。
    printf '  %-34s ' "JSON ボディ (載らないことの確認)"
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
             -X POST -H "X-App-Caller: user" \
             -H "Content-Type: application/json" \
             --data '{"orderId":"C-3","note":"body は属性にならない"}' \
             "${FRONT}/echo" 2>/dev/null || echo "000")
    printf '%s\n' "$([ "${code}" = "200" ] && echo OK || echo "NG HTTP ${code}")"

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

 下流ノード名の多段階判定 (docs/peer-service-resolution.md):
   app_peer=aurora-mysql      <- 下流ノード名 (= X-Ray サービスマップのノード)
   app_peer_src=agent         <- アプリの peer-service-mapping で決まった
   app_peer_src=domain        <- ホスト名の部分一致で決まった
   app_peer_src=port          <- ポート番号で決まった
   app_peer_src=aws           <- AWS SDK 計装の属性で決まった
   app_peer_src=host          <- ★ どれも当たらず FQDN のまま = 名前の付け忘れ。
                                 これで引けたスパンがあれば、その接続先を
                                 APP_PEER_DOMAIN_RULES か Collector の
                                 transform/peer-service-resolve に足す
   ※ コンテナの起動ログ [otel-env] peer 判定 にも段ごとの内訳が出る:
        docker compose logs front | grep "peer 判定" -A 8

 ALB 経由の通信 (docs/alb-tracing.md):
   app_via=alb                <- ALB (プロキシ) を通っている
   app_upstream=report-ec2@…  <- ALB の裏で実際に応答したサーバ
                                 (ターゲットが X-Server-Id を返した場合)
   client_ip=…                <- ALB の手前の実クライアント IP
   alb_trace_id=Root=1-…      <- ALB アクセスログとの結合キー
   ※ ALB のノードはマップに出ない。ALB が X-Ray にセグメントを
     送らないため。ALB での待ち時間を EC2 の処理時間と分けたいときは
     alb_trace_id で ALB アクセスログと突き合わせる

 リクエストの中身 (docs/request-attributes.md):
   url.query                          <- クエリ文字列。token= は REDACTED になる
   http.request.header.x-forwarded-for<- 取り込んだヘッダ (文字列配列)
   servlet.request.parameter.orderid  <- APP_CAPTURE_REQUEST_PARAMETERS を
                                         設定したときだけ出る
   ※ JSON ボディは **どの設定でも出ない**。/api/echo に JSON を POST した
     トレースにボディが無いことが、その確認になる

 X-Ray の indexed_attributes をローカルで検証する (1 つずつ Tags に入れる):
   app_ns=shopdemo            <- service.namespace   (APP_NAMESPACE)
   app_env=local              <- deployment.environment (APP_ENV)
   app_role=back              <- app.role            (APP_ROLE)
   ecs_cluster=shopdemo-local <- aws.ecs.cluster.name
   ecs_service=intra-api      <- aws.ecs.service.name
   ecs_task_family=intra-api-local <- aws.ecs.task.family
   ※ 引けないものは X-Ray でも annotation にならない。
     詳細と対応表: docs/xray-vs-jaeger.md #3

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
