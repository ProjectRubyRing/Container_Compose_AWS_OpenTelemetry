#!/bin/sh
# ログを追う。引数無しなら front / back / adot-collector をまとめて。
set -eu
cd "$(dirname "$0")/.."
if [ $# -gt 0 ]; then
    exec docker compose logs -f "$@"
fi
exec docker compose logs -f front back adot-collector
