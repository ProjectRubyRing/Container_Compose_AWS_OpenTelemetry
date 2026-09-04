#!/bin/sh
# Compose 環境を停止する。--volumes を付けると DB のデータも消す。
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--volumes" ]; then
    docker compose --profile batch down -v
else
    docker compose --profile batch down
fi
