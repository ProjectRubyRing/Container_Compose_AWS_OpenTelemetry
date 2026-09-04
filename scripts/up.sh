#!/bin/sh
# Compose 環境を起動する。--batch を付けると EC2 バッチスタブも動かす。
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--batch" ]; then
    docker compose --profile batch up -d
else
    docker compose up -d
fi
echo ""
docker compose ps
cat <<'MSG'

  Jaeger UI  : http://localhost:16686
  front      : http://localhost:8080/front/api/health
  back       : http://localhost:18080/back/api/health
  ALB (sim)  : http://localhost:8081/front/api/health
  Collector  : http://localhost:13133

  全経路を叩く: ./scripts/smoke-trace.sh
MSG
