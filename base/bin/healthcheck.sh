#!/bin/sh
# =============================================================================
#  base/bin/healthcheck.sh
#
#   コンテナのヘルスチェック。ECS のコンテナヘルスチェックからも
#   compose の healthcheck からも同じものを使う。
#
#   ★ トレース上の注意
#     ヘルスチェックは 30 秒ごとに永久に走る。素直に計装すると X-Ray の
#     大半が /api/health のトレースで埋まり、検索性も料金も悪化する。対策は 2 段:
#       1. Collector の filter プロセッサで /api/health のサーバスパンを落とす
#          (otel/collector-*.yaml の filter/drop-healthcheck)
#       2. 本番は X-Ray 集中サンプリングのルールで /api/health を 0% にする
#          (アプリからの送信自体が止まるのでより確実かつ安価)
#
#     ここでは X-App-Caller: healthcheck を付けておく。上の 2 段を抜けても
#     X-Ray 側で annotation.app_caller = "healthcheck" として特定・除外できる。
#     Collector の filter もこのヘッダを条件のひとつにしている。
#
#   環境変数:
#     HTTP_PORT            待受ポート (front=8080 / back=18080)
#     HEALTHCHECK_PATH     チェック先パス (既定 /api/health)
#     HEALTHCHECK_CONTEXT  WAR のコンテキストルート (既定 /app)
#     HEALTHCHECK_TIMEOUT  タイムアウト秒
# =============================================================================
set -eu

: "${HTTP_PORT:=8080}"
: "${HEALTHCHECK_CONTEXT:=/app}"
: "${HEALTHCHECK_PATH:=/api/health}"
: "${HEALTHCHECK_TIMEOUT:=4}"

URL="http://127.0.0.1:${HTTP_PORT}${HEALTHCHECK_CONTEXT}${HEALTHCHECK_PATH}"

# curl はベースイメージに必ず入れてある (base/Containerfile の curl-minimal)。
# 無い場合は「チェックできない」ことを明示して失敗させる。黙って成功扱いにすると
# 壊れたコンテナが healthy のまま ALB に組み込まれる。
if ! command -v curl >/dev/null 2>&1; then
    echo "[healthcheck] curl がありません。ベースイメージに curl-minimal が入っているか確認してください。" >&2
    exit 1
fi

exec curl -fsS --max-time "${HEALTHCHECK_TIMEOUT}" \
     -H "X-App-Caller: healthcheck" \
     -o /dev/null "${URL}"
