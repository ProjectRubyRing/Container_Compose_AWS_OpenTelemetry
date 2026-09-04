#!/bin/sh
# =============================================================================
#  base/build/apply-cli.sh   (ビルド時のみ実行)
#
#   embed-server で standalone.xml をオフラインのまま書き換える。
#   front / back の Containerfile からも同じスクリプトを呼べるよう、
#   適用対象を --pattern で指定する形にしてある。
#
#     apply-cli.sh --eap-home /opt/eap --config standalone.xml \
#                  --cli-dir /opt/app/cli --pattern '0*.cli' --pattern '1*.cli'
#
#   すべての .cli は if で冪等化してあるので、front/back 側で再適用しても安全。
# =============================================================================
set -eu

EAP_HOME="/opt/eap"
EAP_CONFIG="standalone.xml"
CLI_DIR="/opt/app/cli"
PATTERNS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --eap-home) EAP_HOME="$2"; shift 2 ;;
        --config)   EAP_CONFIG="$2"; shift 2 ;;
        --cli-dir)  CLI_DIR="$2"; shift 2 ;;
        --pattern)  PATTERNS="${PATTERNS} $2"; shift 2 ;;
        *) echo "[apply-cli] ERROR: 不明な引数: $1" >&2; exit 2 ;;
    esac
done

[ -n "${PATTERNS}" ] || { echo "[apply-cli] ERROR: --pattern が 1 つも指定されていません" >&2; exit 2; }
[ -x "${EAP_HOME}/bin/jboss-cli.sh" ] || { echo "[apply-cli] ERROR: ${EAP_HOME}/bin/jboss-cli.sh がありません" >&2; exit 2; }

# 適用対象を列挙する。パターン順 = 適用順 (00 -> 10 -> 20 ...)。
FILES=""
for p in ${PATTERNS}; do
    for f in "${CLI_DIR}"/${p}; do
        [ -f "$f" ] || continue
        FILES="${FILES} ${f}"
    done
done
[ -n "${FILES}" ] || { echo "[apply-cli] ERROR: ${CLI_DIR} に対象の .cli がありません (${PATTERNS})" >&2; exit 2; }

# embed-server のヘッダ/フッタで挟んだ 1 本のスクリプトにまとめる。
# 1 回の embed-server で全部適用することで、設定ブートストラップの回数を
# 最小 (= 1 回) に保つ。
RUNTIME_CLI="$(mktemp /tmp/apply-cli.XXXXXX.cli)"
trap 'rm -f "${RUNTIME_CLI}"' EXIT

{
    echo "embed-server --server-config=${EAP_CONFIG} --std-out=echo"
    for f in ${FILES}; do
        echo "echo \"[apply-cli] ---- $(basename "$f") ----\""
        cat "$f"
        echo ""
    done
    echo "stop-embedded-server"
} > "${RUNTIME_CLI}"

echo "[apply-cli] 適用対象:${FILES}"
"${EAP_HOME}/bin/jboss-cli.sh" --file="${RUNTIME_CLI}"

# ビルド時に作られた履歴はイメージに残さない。
# 残すと overlayfs の下位レイヤになり、起動時の rename が原理的に通らなくなる
# (WFLYCTL0056 / WFLYCTL0414 が毎起動出続ける)。
rm -rf "${EAP_HOME}/standalone/configuration/standalone_xml_history"

echo "[apply-cli] 完了"
