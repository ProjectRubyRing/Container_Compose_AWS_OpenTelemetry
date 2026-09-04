#!/bin/sh
# =============================================================================
#  scripts/check-collector-drift.sh
#
#   otel/collector-compose.yaml と otel/collector-xray.yaml の
#   「共通であるべき部分」がずれていないかを検査する。
#
#  ★ なぜ要るのか
#    本構成は「ローカルで見えたものは X-Ray でも同じ形で見える」ことを
#    保証するために、加工処理 (filter / transform) を両環境で同一に保っている。
#    ところがこの 2 ファイルは別物なので、片方だけ直すと静かにずれる。
#    ずれると「ローカルでは app_caller があるのに X-Ray には無い」といった、
#    本番でしか出ない不具合になる。
#
#    CI に組み込むか、Collector 設定を触ったら必ず実行すること。
#
#  比較対象:
#    - filter/drop-healthcheck の条件
#    - transform/xray-annotations の statements
#    - batch/traces の設定
#
#  意図的に違う箇所 (★XRAY-DIFF コメントが付いている行) は比較しない。
# =============================================================================
set -eu

cd "$(dirname "$0")/.."

A="otel/collector-compose.yaml"
B="otel/collector-xray.yaml"

for f in "$A" "$B"; do
    [ -f "$f" ] || { echo "ERROR: $f がありません" >&2; exit 2; }
done

# YAML のあるブロックだけを抜き出す (コメントと空行は落とす)。
extract() {
    # $1 = ファイル / $2 = ブロック名 (例: "filter/drop-healthcheck:")
    awk -v key="  $2" '
        $0 == key { inblk = 1; print; next }
        inblk {
            # 同じインデント (2 スペース) の次のキーで終了
            if ($0 ~ /^  [a-zA-Z]/) { inblk = 0; next }
            if ($0 ~ /^[a-zA-Z]/)   { inblk = 0; next }
            print
        }
    ' "$1" | sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

rc=0
for block in "filter/drop-healthcheck:" "transform/xray-annotations:" "batch/traces:"; do
    ta=$(extract "$A" "$block")
    tb=$(extract "$B" "$block")
    if [ "$ta" = "$tb" ]; then
        printf '  OK   %s\n' "$block"
    else
        printf '  NG   %s  <- 2 つの Collector 設定でずれています\n' "$block"
        echo "       --- $A"
        printf '%s\n' "$ta" | sed 's/^/       | /'
        echo "       --- $B"
        printf '%s\n' "$tb" | sed 's/^/       | /'
        rc=1
    fi
done

if [ "$rc" = "0" ]; then
    echo ""
    echo "共通ブロックは一致しています (ローカルで見えた属性は X-Ray でも同じ名前で見えます)。"
else
    echo ""
    echo "ずれています。片方だけ直していないか確認してください。" >&2
    echo "意図的に差を付ける場合は、その行に ★XRAY-DIFF コメントを付け、" >&2
    echo "docs/xray-vs-jaeger.md の差分表にも追記してください。" >&2
fi
exit "$rc"
